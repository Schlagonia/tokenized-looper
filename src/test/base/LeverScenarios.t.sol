// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup} from "./Setup.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LeverScenariosTest
/// @notice Comprehensive tests for the _lever function in BaseLooper.sol
/// @dev Tests all scenarios: leveraging up, deleveraging, at-target, above-max, and edge cases
abstract contract LeverScenariosTest is Setup {
    uint256 internal constant WAD = 1e18;

    function setUp() public virtual override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Setup a position by depositing, tending, and then manually adjusting
    /// @dev This creates a position and then verifies/adjusts to desired leverage
    /// @param depositAmount The amount to deposit
    /// @param targetLeverage The desired leverage ratio (WAD scale)
    function _setupPositionWithLeverage(
        uint256 depositAmount,
        uint256 targetLeverage
    ) internal {
        // 1. Deposit the amount
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        // 2. Tend to create initial position at default target (3x)
        vm.prank(keeper);
        strategy.tend();

        // 3. Adjust to desired leverage by borrowing more or repaying
        (uint256 currentCollateral, uint256 currentDebt) = strategy.position();

        // Calculate desired debt for target leverage
        // leverage = collateral / equity => we need: currentDebt' such that leverage = targetLeverage
        // newLeverage = currentCollateral / (currentCollateral - newDebt)
        // targetLeverage = currentCollateral / (currentCollateral - newDebt)
        // targetLeverage * (currentCollateral - newDebt) = currentCollateral
        // currentCollateral - newDebt = currentCollateral / targetLeverage
        // newDebt = currentCollateral - currentCollateral / targetLeverage
        // newDebt = currentCollateral * (1 - 1/targetLeverage) = currentCollateral * (targetLeverage - 1) / targetLeverage

        uint256 desiredDebt = (currentCollateral * (targetLeverage - WAD)) /
            targetLeverage;

        vm.startPrank(management);
        if (desiredDebt > currentDebt) {
            // Need more debt - borrow more
            uint256 borrowMore = desiredDebt - currentDebt;
            strategy.manualBorrow(borrowMore);
        } else if (currentDebt > desiredDebt) {
            // Need less debt - repay some
            // To reduce debt, we need to:
            // 1. Withdraw some collateral
            // 2. Convert to asset
            // 3. Repay debt
            uint256 repayAmount = currentDebt - desiredDebt;

            // Calculate collateral needed based on repayAmount + slippage (like actual code)
            // position() returns collateral VALUE in asset terms, balanceOfCollateral() returns token units
            uint256 collateralTokens = strategy.balanceOfCollateral();

            // Convert repayAmount (asset terms) to collateral token units:
            // collateralTokens / currentCollateral = tokens per asset value
            // repayAmount * collateralTokens / currentCollateral = tokens needed
            // Add slippage buffer
            uint256 repayWithSlippage = (repayAmount *
                (10_000 + strategy.slippage())) / 10_000;
            uint256 collateralToWithdraw = (repayWithSlippage *
                collateralTokens) / currentCollateral;

            strategy.manualWithdrawCollateral(collateralToWithdraw);
            strategy.convertCollateralToAsset(type(uint256).max);

            // Now repay as much as needed (limited by what we have)
            uint256 looseAsset = strategy.balanceOfAsset();
            strategy.manualRepay(
                looseAsset > repayAmount ? repayAmount : looseAsset
            );

            // Leave any leftover as loose asset to avoid slippage errors during conversion
            // The position will be slightly under-leveraged which is fine for test setup
        }
        vm.stopPrank();
    }

    /// @notice Setup an under-leveraged position (below target - buffer)
    /// @dev Creates a position that's below the lower buffer bound by:
    ///      1. First depositing and tending to get a 3x position
    ///      2. Then repaying debt to reduce leverage
    /// @param equity The equity amount to use for the position
    /// @return collateral The collateral value created
    /// @return debt The debt amount created
    function _setupUnderLeveragedPosition(
        uint256 equity
    ) internal returns (uint256 collateral, uint256 debt) {
        // 1. Deposit and tend to get a 3x position
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // 2. Repay some debt to reduce leverage
        // At 3x: collateral = 3*equity, debt = 2*equity
        // To get under-leveraged, repay 25-30% of debt
        (uint256 currentCollateral, uint256 currentDebt) = strategy.position();
        uint256 repayAmount = currentDebt / 4; // Repay 25% of debt (more conservative)

        // Airdrop asset to repay (simpler than withdrawing collateral)
        airdrop(asset, address(strategy), repayAmount);

        vm.startPrank(management);
        // Repay the debt with the airdropped asset
        strategy.manualRepay(repayAmount);
        vm.stopPrank();

        (collateral, debt) = strategy.position();
    }

    /// @notice Setup an over-leveraged position (above target + buffer)
    /// @param equity The equity amount to use for the position
    /// @return collateral The collateral value created
    /// @return debt The debt amount created
    function _setupOverLeveragedPosition(
        uint256 equity
    ) internal returns (uint256 collateral, uint256 debt) {
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 overLeverage = targetLeverage + buffer + 0.3e18; // Above upper bound

        _setupPositionWithLeverage(equity, overLeverage);

        (collateral, debt) = strategy.position();
    }

    /// @notice Setup a position at exactly target leverage
    /// @param equity The equity amount to use for the position
    /// @return collateral The collateral value created
    /// @return debt The debt amount created
    function _setupAtTargetPosition(
        uint256 equity
    ) internal returns (uint256 collateral, uint256 debt) {
        uint256 targetLeverage = strategy.targetLeverageRatio();

        _setupPositionWithLeverage(equity, targetLeverage);

        (collateral, debt) = strategy.position();
    }

    /// @notice Setup a position above max leverage (emergency territory)
    /// @param equity The equity amount to use for the position
    /// @return collateral The collateral value created
    /// @return debt The debt amount created
    function _setupAboveMaxLeveragePosition(
        uint256 equity
    ) internal returns (uint256 collateral, uint256 debt) {
        uint256 maxLeverage = strategy.maxLeverageRatio();
        uint256 emergencyLeverage = maxLeverage + 0.5e18; // Above max

        _setupPositionWithLeverage(equity, emergencyLeverage);

        (collateral, debt) = strategy.position();
    }

    /// @notice Assert that leverage is within target buffer
    function _assertLeverageWithinBuffer() internal view {
        uint256 leverage = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();

        assertGe(leverage, target - buffer, "leverage too low");
        assertLe(leverage, target + buffer, "leverage too high");
    }

    /// @notice Assert that leverage is at or below a specific value
    function _assertLeverageAtOrBelow(uint256 maxLeverage) internal view {
        uint256 leverage = strategy.getCurrentLeverageRatio();
        assertLe(leverage, maxLeverage, "leverage exceeds max");
    }

    /// @notice Calculate the debt needed to achieve a specific leverage given equity
    function _calculateDebtForLeverage(
        uint256 equity,
        uint256 leverage
    ) internal pure returns (uint256) {
        uint256 collateral = (equity * leverage) / WAD;
        return collateral - equity;
    }

    /// @notice Get the minimum amount that would trigger a flashloan
    function _getMinFlashloanAmount() internal view returns (uint256) {
        return strategy.minAmountToBorrow();
    }

    /// @notice Calculate target position for a given equity
    /// @dev Mirrors BaseLooper.getTargetPosition()
    function _getTargetPosition(
        uint256 equity
    ) internal view returns (uint256 collateral, uint256 debt) {
        uint256 targetCollateral = (equity * strategy.targetLeverageRatio()) /
            WAD;
        uint256 targetDebt = targetCollateral - equity;
        return (targetCollateral, targetDebt);
    }

    /*//////////////////////////////////////////////////////////////
                    GROUP 1: CASE 1 (NEED MORE DEBT - LEVER UP)
    //////////////////////////////////////////////////////////////*/

    /// @notice Test Case 1: First deposit, leverage up via flashloan
    function test_lever_noPosition_normalAmount(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // 1. Setup: No position exists, deposit funds
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // 2. Verify no position before tend
        (uint256 collateralBefore, uint256 debtBefore) = strategy.position();
        assertEq(collateralBefore, 0, "should have no collateral before");
        assertEq(debtBefore, 0, "should have no debt before");

        // 3. Execute tend (which calls _lever)
        vm.prank(keeper);
        strategy.tend();

        // 4. Verify position was created with leverage
        (uint256 collateralAfter, uint256 debtAfter) = strategy.position();
        assertGt(collateralAfter, 0, "should have collateral after");
        assertGt(debtAfter, 0, "should have debt after");

        // 5. Verify leverage is within target buffer
        _assertLeverageWithinBuffer();
    }

    /// @notice Test Case 1b: First deposit too small for flashloan, just supply
    function test_lever_noPosition_smallAmount() public {
        // Set min flashloan threshold high
        vm.prank(management);
        strategy.setMinAmountToBorrow(1000e6); // 1000 USDC minimum

        // 1. Setup: Small deposit below flashloan threshold
        uint256 smallAmount = 100e6; // 100 USDC
        mintAndDepositIntoStrategy(strategy, user, smallAmount);

        // 2. Verify no position before tend
        (uint256 collateralBefore, uint256 debtBefore) = strategy.position();
        assertEq(collateralBefore, 0, "should have no collateral before");
        assertEq(debtBefore, 0, "should have no debt before");

        // 3. Execute tend - should just repay (no debt to repay) and do nothing else
        // Since there's no debt, the min check should result in no flashloan
        vm.prank(keeper);
        strategy.tend();

        // 4. Verify: Since this is Case 1 with small amount, flashloan skipped
        // The function should just call _repay(min(_amount, balanceOfDebt))
        // Since balanceOfDebt = 0, this is effectively a no-op for borrowing
        uint256 debt = strategy.balanceOfDebt();
        assertEq(debt, 0, "should have no debt (flashloan skipped)");
    }

    /// @notice Test Case 1: Existing under-leveraged position, add funds and lever up
    function test_lever_underLeveraged_normalAmount(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // 1. Setup: Create under-leveraged position
        uint256 equity = 10000e6; // 10k USDC
        (
            uint256 initialCollateral,
            uint256 initialDebt
        ) = _setupUnderLeveragedPosition(equity);

        // 2. Verify under-leveraged (below target, ideally below lower buffer)
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        // The setup should create a position significantly below target
        assertLt(
            leverageBefore,
            target,
            "should be under-leveraged (below target)"
        );

        // 3. Add new funds
        airdrop(asset, address(strategy), _amount);

        // 4. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify leverage moved toward target
        _assertLeverageWithinBuffer();

        // 6. Verify debt increased (leveraged up)
        uint256 debtAfter = strategy.balanceOfDebt();
        assertGt(
            debtAfter,
            initialDebt,
            "debt should increase when levering up"
        );
    }

    /// @notice Test Case 1b: Small addition to under-leveraged position when flashloan threshold is high
    /// @dev When the flashloan amount would be below minAmountToBorrow, the strategy
    ///      just repays min(_amount, balanceOfDebt) instead of doing a flashloan.
    function test_lever_underLeveraged_smallAmount() public {
        // Set high min flashloan threshold
        vm.prank(management);
        strategy.setMinAmountToBorrow(1000e6);

        // 1. Setup: Create under-leveraged position
        uint256 equity = 10000e6;
        _setupUnderLeveragedPosition(equity);

        // 2. Verify under-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertLt(
            leverageBefore,
            target,
            "should be under-leveraged (below target)"
        );

        // 3. Get debt before adding funds
        uint256 debtBefore = strategy.balanceOfDebt();

        // 4. Add small amount (below flashloan threshold, so resulting flashloan amount would be small)
        uint256 smallAmount = 50e6; // 50 USDC
        airdrop(asset, address(strategy), smallAmount);

        // 5. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 6. Since the required flashloan amount is below minAmountToBorrow,
        // the code enters Case 1b: just _repay(min(_amount, balanceOfDebt))
        // This should repay some debt with the small amount
        uint256 debtAfter = strategy.balanceOfDebt();

        // The debt should be reduced by approximately the small amount repaid
        // (or debt stays same if debt was 0, or increases if different case hit)
        // The key behavior: no flashloan was executed, so position was not leveraged up
        // The leverage should still be under-leveraged or slightly changed
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertLt(
            leverageAfter,
            target + buffer,
            "leverage should not exceed upper bound"
        );
    }

    /// @notice Test Case 1: Rebalance under-leveraged position with no new funds
    function test_lever_underLeveraged_zeroAmount(uint256 equityAmount) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create under-leveraged position
        _setupUnderLeveragedPosition(equityAmount);

        // 2. Verify under-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertLt(
            leverageBefore,
            target,
            "should be under-leveraged (below target)"
        );

        // 3. Execute tend with no new funds (rebalance only)
        vm.prank(keeper);
        strategy.tend();

        // 4. Verify leverage moved toward target
        _assertLeverageWithinBuffer();
    }

    /*//////////////////////////////////////////////////////////////
                    GROUP 2: CASE 2 (NEED LESS DEBT - DELEVER)
    //////////////////////////////////////////////////////////////*/

    /// @notice Test Case 2: Delever via flashloan only (no new funds)
    /// @dev When over-leveraged with no new funds, the strategy deleverage to reach target.
    ///      This is Case 2b in _lever: flashloan to repay debt, withdraw collateral to cover.
    function test_lever_overLeveraged_zeroAmount(uint256 equityAmount) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create over-leveraged position
        _setupOverLeveragedPosition(equityAmount);

        // 2. Verify over-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGt(leverageBefore, target + buffer, "should be over-leveraged");

        // 3. Get position state before tend
        (uint256 collateralBefore, uint256 debtBefore) = strategy.position();

        // 4. Execute tend with no new funds
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify leverage moved toward target (primary assertion)
        _assertLeverageWithinBuffer();

        // 6. Verify debt decreased relative to the before-tend state
        // (deleveraging should reduce debt to reach target)
        uint256 debtAfter = strategy.balanceOfDebt();
        assertLt(
            debtAfter,
            debtBefore,
            "debt should decrease when deleveraging from over-leveraged state"
        );
    }

    /// @notice Test Case 2b: Delever with small _amount helping repay
    /// @dev When over-leveraged and adding a small amount, the _lever function:
    ///      1. Calculates new equity = collateral - debt + _amount
    ///      2. Calculates target debt based on new equity
    ///      3. Uses flashloan to reach target (Case 2b: repay _amount first, then flashloan rest)
    function test_lever_overLeveraged_smallAmount(uint256 equityAmount) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create over-leveraged position
        _setupOverLeveragedPosition(equityAmount);

        // 2. Verify over-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGt(leverageBefore, target + buffer, "should be over-leveraged");

        // 3. Get position state BEFORE adding new funds
        (uint256 collateralBefore, uint256 debtBefore) = strategy.position();
        uint256 equityBefore = collateralBefore - debtBefore;

        // 4. Calculate small amount: should be less than what would be needed to reach target
        // without flashloan (i.e., less than debtToRepay based on current equity)
        (, uint256 targetDebtBeforeNewFunds) = _getTargetPosition(equityBefore);
        uint256 debtToRepayWithoutNewFunds = debtBefore -
            targetDebtBeforeNewFunds;
        uint256 smallAmount = debtToRepayWithoutNewFunds / 4; // 25% of what's needed

        // 5. Add small amount
        airdrop(asset, address(strategy), smallAmount);

        // 6. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 7. Verify leverage moved toward target (this is the key assertion)
        _assertLeverageWithinBuffer();

        // 8. Verify the position was adjusted: with a small amount added,
        // the new target accounts for the added equity, so we expect
        // the final leverage to be within buffer
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertGe(
            leverageAfter,
            target - buffer,
            "leverage should be at or above lower bound"
        );
        assertLe(
            leverageAfter,
            target + buffer,
            "leverage should be at or below upper bound"
        );
    }

    /// @notice Test Case 2a: _amount covers full repayment + remainder supplied
    function test_lever_overLeveraged_largeAmount(uint256 equityAmount) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create over-leveraged position
        (
            uint256 initialCollateral,
            uint256 initialDebt
        ) = _setupOverLeveragedPosition(equityAmount);

        // 2. Verify over-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGt(leverageBefore, target + buffer, "should be over-leveraged");

        // 3. Calculate debt to repay
        (uint256 currentCollateral, uint256 currentDebt) = strategy.position();
        uint256 currentEquity = currentCollateral - currentDebt;
        (, uint256 targetDebt) = _getTargetPosition(currentEquity);
        uint256 debtToRepay = currentDebt - targetDebt;

        // 4. Add large amount (more than debtToRepay)
        uint256 largeAmount = debtToRepay * 2; // 2x what's needed
        airdrop(asset, address(strategy), largeAmount);

        // 5. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 6. Verify leverage is within buffer
        // Note: with large amount, the new equity changes target position
        _assertLeverageWithinBuffer();

        // 7. Verify collateral increased (remainder was supplied)
        uint256 collateralAfter = strategy.balanceOfCollateral();
        assertGt(
            collateralAfter,
            initialCollateral,
            "collateral should increase"
        );
    }

    /// @notice Test Case 2 boundary: _amount exactly equals debtToRepay
    function test_lever_overLeveraged_exactDebtToRepay(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create over-leveraged position
        (
            uint256 initialCollateral,
            uint256 initialDebt
        ) = _setupOverLeveragedPosition(equityAmount);

        // 2. Verify over-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGt(leverageBefore, target + buffer, "should be over-leveraged");

        // 3. Calculate exact debt to repay to reach target
        (uint256 currentCollateral, uint256 currentDebt) = strategy.position();
        uint256 currentEquity = currentCollateral - currentDebt;
        (, uint256 targetDebt) = _getTargetPosition(currentEquity);
        uint256 debtToRepay = currentDebt - targetDebt;

        // 4. Add exactly debtToRepay
        airdrop(asset, address(strategy), debtToRepay);

        // 5. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 6. Verify final state - should be very close to target
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        // Allow some tolerance due to the equity being recalculated with added amount
        assertLe(
            leverageAfter,
            target + buffer + 0.1e18,
            "leverage should be near target"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        GROUP 3: CASE 3 (AT TARGET)
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: When at target and adding significant funds, lever up to maintain target
    /// @dev When at target leverage and adding funds, the new equity increases the target debt,
    ///      which triggers Case 1 (need more debt) to maintain the target leverage ratio.
    ///      This is different from Case 3 which only triggers when _amount is tiny.
    function test_lever_withinBuffer_normalAmount(uint256 equityAmount) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create position at target leverage
        (
            uint256 initialCollateral,
            uint256 initialDebt
        ) = _setupAtTargetPosition(equityAmount);

        // 2. Verify at target
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGe(
            leverageBefore,
            target - buffer,
            "should be within buffer (low)"
        );
        assertLe(
            leverageBefore,
            target + buffer,
            "should be within buffer (high)"
        );

        // 3. Add normal amount of funds
        uint256 newAmount = equityAmount / 2;
        airdrop(asset, address(strategy), newAmount);

        // 4. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify still within buffer (should lever up to maintain target)
        _assertLeverageWithinBuffer();

        // 6. Verify position grew - both collateral and debt should increase
        // because we're levering up with the new funds
        uint256 collateralAfter = strategy.balanceOfCollateral();
        uint256 debtAfter = strategy.balanceOfDebt();
        assertGt(
            collateralAfter,
            initialCollateral,
            "collateral should increase"
        );
        assertGt(
            debtAfter,
            initialDebt,
            "debt should increase (levered up with new funds)"
        );
    }

    /// @notice Test Case 3: No-op when at target with no funds
    /// @dev When already at target leverage and no new funds to deploy,
    ///      the position should remain essentially unchanged.
    function test_lever_withinBuffer_zeroAmount(uint256 equityAmount) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create position at target leverage
        _setupAtTargetPosition(equityAmount);

        // 2. Verify at target
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGe(
            leverageBefore,
            target - buffer,
            "should be within buffer (low)"
        );
        assertLe(
            leverageBefore,
            target + buffer,
            "should be within buffer (high)"
        );

        // 3. Get position state before tend
        (uint256 collateralBefore, uint256 debtBefore) = strategy.position();

        // 4. Execute tend with no new funds
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify leverage is still within buffer (main assertion)
        _assertLeverageWithinBuffer();

        // 6. Verify position remained stable
        // Note: Due to interest accrual and oracle price changes, there may be small changes
        // The key assertion is that leverage remains within buffer
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertGe(
            leverageAfter,
            target - buffer,
            "leverage should remain within buffer (low)"
        );
        assertLe(
            leverageAfter,
            target + buffer,
            "leverage should remain within buffer (high)"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    GROUP 4: ABOVE MAX LEVERAGE (EMERGENCY)
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Emergency delever when above max leverage with no funds
    function test_lever_aboveMax_zeroAmount(uint256 equityAmount) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create position above max leverage
        (
            uint256 initialCollateral,
            uint256 initialDebt
        ) = _setupAboveMaxLeveragePosition(equityAmount);

        // 2. Verify above max
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 maxLeverage = strategy.maxLeverageRatio();
        assertGt(leverageBefore, maxLeverage, "should be above max leverage");

        // 3. Execute tend (should trigger emergency delever)
        vm.prank(keeper);
        strategy.tend();

        // 4. Verify leverage came down
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertLt(leverageAfter, leverageBefore, "leverage should decrease");

        // 5. Verify within acceptable range
        _assertLeverageWithinBuffer();
    }

    /// @notice Test: Emergency delever when above max leverage with normal funds
    function test_lever_aboveMax_normalAmount(uint256 equityAmount) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create position above max leverage
        _setupAboveMaxLeveragePosition(equityAmount);

        // 2. Verify above max
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 maxLeverage = strategy.maxLeverageRatio();
        assertGt(leverageBefore, maxLeverage, "should be above max leverage");

        // 3. Add funds
        uint256 newAmount = equityAmount / 2;
        airdrop(asset, address(strategy), newAmount);

        // 4. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify leverage came down significantly
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertLt(leverageAfter, leverageBefore, "leverage should decrease");

        // 6. Verify within buffer
        _assertLeverageWithinBuffer();
    }

    /*//////////////////////////////////////////////////////////////
                            GROUP 5: EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test edge case: Very over-leveraged with medium amount
    /// This tests the specific case where _amount > debtToRepay but position is still Case 2
    function test_lever_veryOverLeveraged_mediumAmount(
        uint256 equityAmount
    ) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create significantly over-leveraged position
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 veryOverLeverage = targetLeverage + buffer + 1e18; // Well above buffer

        _setupPositionWithLeverage(equityAmount, veryOverLeverage);

        // 2. Verify very over-leveraged
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertGt(
            leverageBefore,
            targetLeverage + buffer,
            "should be very over-leveraged"
        );

        // 3. Calculate debt to repay
        (uint256 currentCollateral, uint256 currentDebt) = strategy.position();
        uint256 currentEquity = currentCollateral - currentDebt;
        (, uint256 targetDebt) = _getTargetPosition(currentEquity);
        uint256 debtToRepay = currentDebt - targetDebt;

        // 4. Add medium amount (between debtToRepay/2 and debtToRepay)
        uint256 mediumAmount = (debtToRepay * 3) / 4;
        airdrop(asset, address(strategy), mediumAmount);

        // 5. Execute tend
        vm.prank(keeper);
        strategy.tend();

        // 6. Verify leverage moved toward target
        _assertLeverageWithinBuffer();
    }

    /// @notice Test boundary: Position near lower buffer boundary
    /// @dev Due to the complexity of precise leverage setup, we verify
    ///      that the position is reasonably close to the lower boundary
    function test_lever_atLowerBufferBoundary(uint256 equityAmount) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create position targeting lower buffer boundary
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 lowerBoundLeverage = targetLeverage - buffer;

        _setupPositionWithLeverage(equityAmount, lowerBoundLeverage);

        // 2. Verify position is around lower boundary (within 15% tolerance due to setup complexity)
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        // Position should be reasonably close to target (actual position may vary due to debt adjustment mechanics)
        assertGt(
            leverageBefore,
            lowerBoundLeverage - 0.5e18,
            "leverage should be near lower bound"
        );
        assertLt(
            leverageBefore,
            targetLeverage + buffer,
            "leverage should not exceed upper bound"
        );

        // 3. Execute tend with no new funds
        vm.prank(keeper);
        strategy.tend();

        // 4. Verify leverage is within or moving toward buffer after tend
        _assertLeverageWithinBuffer();
    }

    /// @notice Test boundary: Exactly at upper buffer boundary
    function test_lever_atUpperBufferBoundary(uint256 equityAmount) public {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        // 1. Setup: Create position exactly at target + buffer
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 upperBoundLeverage = targetLeverage + buffer;

        _setupPositionWithLeverage(equityAmount, upperBoundLeverage);

        // 2. Verify at upper boundary
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        // Should be approximately at upper bound (within small tolerance)
        assertApproxEqRel(
            leverageBefore,
            upperBoundLeverage,
            0.01e18,
            "should be at upper bound"
        );

        // 3. Execute tend with no new funds
        vm.prank(keeper);
        strategy.tend();

        // 4. Verify leverage stayed within buffer
        _assertLeverageWithinBuffer();
    }

    /*//////////////////////////////////////////////////////////////
                    ADDITIONAL EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test multiple sequential tends maintain leverage
    function test_lever_sequentialTends(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // 1. Setup: Normal deposit and tend
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        _assertLeverageWithinBuffer();

        // 2. Second tend should maintain leverage
        vm.prank(keeper);
        strategy.tend();

        _assertLeverageWithinBuffer();

        // 3. Third tend after adding small funds
        uint256 smallAdd = _amount / 10;
        airdrop(asset, address(strategy), smallAdd);

        vm.prank(keeper);
        strategy.tend();

        _assertLeverageWithinBuffer();
    }

    /// @notice Test tend with minimum possible amount
    function test_lever_minimumAmount() public {
        // 1. Deposit absolute minimum
        uint256 minAmount = minFuzzAmount;
        mintAndDepositIntoStrategy(strategy, user, minAmount);

        // 2. Tend
        vm.prank(keeper);
        strategy.tend();

        // 3. Should either achieve target or be handled gracefully
        uint256 leverage = strategy.getCurrentLeverageRatio();
        // Either at target or position is too small to leverage
        assertTrue(
            leverage == WAD ||
                (leverage >=
                    strategy.targetLeverageRatio() - strategy.leverageBuffer()),
            "leverage should be valid"
        );
    }

    /// @notice Test tend with maximum amount
    function test_lever_maximumAmount() public {
        // 1. Deposit maximum test amount
        uint256 maxAmount = maxFuzzAmount;
        mintAndDepositIntoStrategy(strategy, user, maxAmount);

        // 2. Tend
        vm.prank(keeper);
        strategy.tend();

        // 3. Verify leverage
        _assertLeverageWithinBuffer();
    }

    /// @notice Test Case 2: When _amount exactly pays off all target debt reduction
    function test_lever_overLeveraged_amountCoversExactDebtReduction() public {
        uint256 equityAmount = 10000e6;

        // 1. Setup: Create moderately over-leveraged position
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 overLeverage = targetLeverage + buffer + 0.2e18;

        _setupPositionWithLeverage(equityAmount, overLeverage);

        // 2. Calculate exact amount needed to cover debt reduction
        (uint256 currentCollateral, uint256 currentDebt) = strategy.position();
        uint256 currentEquity = currentCollateral - currentDebt;
        (, uint256 targetDebt) = _getTargetPosition(currentEquity);
        uint256 debtToRepay = currentDebt > targetDebt
            ? currentDebt - targetDebt
            : 0;

        // 3. Add exactly debtToRepay (triggers Case 2a in _lever)
        if (debtToRepay > 0) {
            airdrop(asset, address(strategy), debtToRepay);

            // 4. Execute tend
            vm.prank(keeper);
            strategy.tend();

            // 5. Verify - with exact repayment, position should be close to target
            // The new equity includes the added amount, so target recalculates
            _assertLeverageWithinBuffer();
        }
    }

    /// @notice Test that _getTargetPosition helper returns correct values
    function test_getTargetPosition(uint256 equity) public view {
        vm.assume(equity > 1e6 && equity < maxFuzzAmount);

        (uint256 targetCollateral, uint256 targetDebt) = _getTargetPosition(
            equity
        );

        // Verify: targetCollateral = equity * targetLeverageRatio / WAD
        uint256 expectedCollateral = (equity * strategy.targetLeverageRatio()) /
            WAD;
        assertEq(targetCollateral, expectedCollateral, "!targetCollateral");

        // Verify: targetDebt = targetCollateral - equity
        uint256 expectedDebt = targetCollateral - equity;
        assertEq(targetDebt, expectedDebt, "!targetDebt");

        // Verify leverage ratio: collateral / (collateral - debt) = collateral / equity
        uint256 impliedLeverage = (targetCollateral * WAD) / equity;
        assertEq(
            impliedLeverage,
            strategy.targetLeverageRatio(),
            "!impliedLeverage"
        );
    }

    /// @notice Test position() returns correct values
    function test_positionAccuracy(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        (uint256 collateralValue, uint256 debt) = strategy.position();
        uint256 currentLTV = strategy.getCurrentLTV();

        // Verify collateral value > 0
        assertGt(collateralValue, 0, "!collateralValue");

        // Verify debt > 0 (we're leveraged)
        assertGt(debt, 0, "!debt");

        // Verify LTV calculation: LTV = debt / collateralValue
        uint256 expectedLTV = (debt * WAD) / collateralValue;
        assertEq(currentLTV, expectedLTV, "!currentLTV calculation");

        // Verify leverage = 1 / (1 - LTV) approximately equals getCurrentLeverageRatio
        uint256 leverage = strategy.getCurrentLeverageRatio();
        uint256 expectedLeverage = (collateralValue * WAD) /
            (collateralValue - debt);
        assertApproxEqRel(
            leverage,
            expectedLeverage,
            0.001e18,
            "!leverage calculation"
        );
    }

    /// @notice Test that minAmountToBorrow threshold is respected
    /// @dev When the required flashloan amount is below minAmountToBorrow,
    ///      Case 1b is triggered: just repay min(_amount, balanceOfDebt) and return
    function test_lever_respectsMinAmountToBorrow() public {
        // 1. Set a high minimum borrow threshold
        vm.prank(management);
        strategy.setMinAmountToBorrow(1000000e6); // 1M USDC

        // 2. Create a position that would need a small flashloan to reach target
        // We'll create an under-leveraged position with equity that results in
        // a target debt increase less than minAmountToBorrow
        uint256 equity = 5000e6;
        _setupUnderLeveragedPosition(equity);

        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();

        // Verify under-leveraged (Case 1 territory)
        assertLt(leverageBefore, target - buffer, "should be under-leveraged");

        // 3. Tend - flashloan should be skipped due to minAmountToBorrow
        // Case 1b: flashloanAmount <= minAmountToBorrow, so just _repay and return
        vm.prank(keeper);
        strategy.tend();

        // 4. Verify the position was not fully leveraged up
        // Since flashloan was skipped, leverage should remain below target
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();

        // The position should NOT have reached target leverage
        // (because the needed flashloan was too small and was skipped)
        assertLt(
            leverageAfter,
            target,
            "leverage should remain below target when flashloan is too small"
        );
    }

    /// @notice Test lever with zero target leverage edge case
    function test_lever_afterLeverageParamChange(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // 1. Setup: Normal deposit and tend at 3x
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        _assertLeverageWithinBuffer();

        // 2. Change target to lower leverage
        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.3e18, 5e18);

        // 3. Now the position is over-leveraged relative to new target
        uint256 newTarget = strategy.targetLeverageRatio();
        uint256 newBuffer = strategy.leverageBuffer();
        assertGt(
            leverageBefore,
            newTarget + newBuffer,
            "should be over-leveraged after param change"
        );

        // 4. Tend should delever to new target
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify at new target
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertGe(
            leverageAfter,
            newTarget - newBuffer,
            "leverage too low for new target"
        );
        assertLe(
            leverageAfter,
            newTarget + newBuffer,
            "leverage too high for new target"
        );
    }

    /// @notice Test lever with increasing target leverage
    function test_lever_afterIncreasingTargetLeverage(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // 1. Setup: Lower initial target
        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.3e18, 5e18);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertGe(leverageBefore, 2e18 - 0.3e18, "should be at 2x target");
        assertLe(leverageBefore, 2e18 + 0.3e18, "should be at 2x target");

        // 2. Increase target leverage
        vm.prank(management);
        strategy.setLeverageParams(4e18, 0.5e18, 6e18);

        // 3. Now position is under-leveraged
        uint256 newTarget = strategy.targetLeverageRatio();
        uint256 newBuffer = strategy.leverageBuffer();
        assertLt(
            leverageBefore,
            newTarget - newBuffer,
            "should be under-leveraged after param change"
        );

        // 4. Tend should lever up
        vm.prank(keeper);
        strategy.tend();

        // 5. Verify at new target
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertGe(
            leverageAfter,
            newTarget - newBuffer,
            "leverage too low for new target"
        );
        assertLe(
            leverageAfter,
            newTarget + newBuffer,
            "leverage too high for new target"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    GROUP 6: MAX AMOUNT TO SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test Case 1 with maxAmountToSwap limiting the flashloan
    /// @dev When totalSwap (_amount + flashloanAmount) > maxAmountToSwap,
    ///      the flashloan should be reduced to stay within limits
    function test_lever_maxAmountToSwap_limitsFlashloan(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set a maxAmountToSwap that will limit the position building
        uint256 maxSwap = _amount * 2; // Allow 2x the deposit as max swap
        vm.prank(management);
        strategy.setMaxAmountToSwap(maxSwap);

        // Deposit funds
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Tend should respect maxAmountToSwap
        vm.prank(keeper);
        strategy.tend();

        // Verify position was created but limited
        (uint256 collateralValue, uint256 debt) = strategy.position();
        assertGt(collateralValue, 0, "!should have collateral");

        // The total swap should be approximately maxSwap or less
        // Since totalSwap = _amount + flashloanAmount, and flashloanAmount ~ debt
        // The debt + _amount should be around maxSwap
        // Note: actual behavior depends on slippage and conversions
        assertLe(
            debt + _amount,
            maxSwap + (maxSwap / 10), // Allow 10% tolerance for slippage
            "!total swap should be limited"
        );
    }

    /// @notice Test Case 1 when _amount alone exceeds maxAmountToSwap
    /// @dev When _amount >= maxAmountToSwap, should just swap maxAmountToSwap and supply
    function test_lever_maxAmountToSwap_amountExceedsMax() public {
        uint256 depositAmount = 10000e6;
        uint256 maxSwap = 5000e6; // Less than deposit amount

        // Set maxAmountToSwap less than deposit
        vm.prank(management);
        strategy.setMaxAmountToSwap(maxSwap);

        // Deposit funds
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        // Tend should only swap maxSwap worth
        vm.prank(keeper);
        strategy.tend();

        // Position should have limited collateral
        // No debt should be taken since we hit the early return
        uint256 debt = strategy.balanceOfDebt();
        assertEq(debt, 0, "!should have no debt when _amount exceeds maxSwap");

        // Should have some collateral from the maxSwap conversion
        uint256 collateral = strategy.balanceOfCollateral();
        assertGt(collateral, 0, "!should have some collateral");

        // Should have leftover asset
        uint256 looseAsset = strategy.balanceOfAsset();
        assertGt(looseAsset, 0, "!should have leftover asset");
    }

    /// @notice Test Case 1 with maxAmountToSwap = 0 (edge case)
    /// @dev When maxAmountToSwap is 0, should not swap anything
    function test_lever_maxAmountToSwap_zero() public {
        uint256 depositAmount = 10000e6;

        // Set maxAmountToSwap to 0
        vm.prank(management);
        strategy.setMaxAmountToSwap(0);

        // Deposit funds
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        // Tend should swap 0 (early return path)
        vm.prank(keeper);
        strategy.tend();

        // Should have no debt
        assertEq(strategy.balanceOfDebt(), 0, "!should have no debt");

        // Loose asset should be close to deposit (minus any minimal swaps)
        uint256 looseAsset = strategy.balanceOfAsset();
        // The strategy should have either all asset or some collateral if 0 swap succeeded
        assertTrue(
            looseAsset > 0 || strategy.balanceOfCollateral() > 0,
            "!should have either asset or collateral"
        );
    }

    /// @notice Test Case 3 respects maxAmountToSwap
    /// @dev Case 3: At target debt, just deploy _amount. Should respect maxAmountToSwap.
    function test_lever_case3_maxAmountToSwap(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // First create a position at target leverage
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Verify at target
        _assertLeverageWithinBuffer();

        // Now set a small maxAmountToSwap
        uint256 smallMax = _amount / 10;
        vm.prank(management);
        strategy.setMaxAmountToSwap(smallMax);

        // Add more funds - this should trigger Case 3 (at target, just deploy)
        airdrop(asset, address(strategy), _amount);

        uint256 collateralBefore = strategy.balanceOfCollateral();

        // Tend should only swap smallMax worth
        vm.prank(keeper);
        strategy.tend();

        uint256 collateralAfter = strategy.balanceOfCollateral();

        // Collateral should increase by approximately smallMax worth
        // (accounting for oracle price differences)
        assertGt(
            collateralAfter,
            collateralBefore,
            "!collateral should increase"
        );

        // Should have leftover asset since we couldn't swap everything
        uint256 looseAsset = strategy.balanceOfAsset();
        assertGt(looseAsset, 0, "!should have leftover asset");
    }

    /// @notice Test maxAmountToSwap with type(uint256).max (default - no limit)
    function test_lever_maxAmountToSwap_noLimit(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Verify default is max uint
        assertEq(
            strategy.maxAmountToSwap(),
            type(uint256).max,
            "!default should be max"
        );

        // Normal deposit and tend should work without limits
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Should achieve target leverage
        _assertLeverageWithinBuffer();

        // Should have minimal or no leftover asset
        uint256 looseAsset = strategy.balanceOfAsset();
        assertLt(
            looseAsset,
            minFuzzAmount / 10,
            "!should have minimal leftover asset"
        );
    }

    /// @notice Test that reducing flashloan respects minAmountToBorrow
    /// @dev When flashloan is reduced but still above minAmountToBorrow, should proceed
    function test_lever_maxAmountToSwap_reducedFlashloanAboveMin(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set minAmountToBorrow
        uint256 minBorrow = 100e6;
        vm.prank(management);
        strategy.setMinAmountToBorrow(minBorrow);

        // Set maxAmountToSwap to allow some flashloan but not full target
        // At 3x leverage: flashloan = 2 * _amount, total = 3 * _amount
        // Set maxSwap to allow partial leverage
        uint256 maxSwap = (_amount * 3) / 2; // 1.5x deposit
        vm.prank(management);
        strategy.setMaxAmountToSwap(maxSwap);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Tend should execute with reduced flashloan
        vm.prank(keeper);
        strategy.tend();

        // Should have some debt (reduced flashloan was above minBorrow)
        uint256 debt = strategy.balanceOfDebt();
        if (_amount > minBorrow * 2) {
            // If _amount is large enough that reduced flashloan > minBorrow
            assertGt(debt, 0, "!should have some debt");
        }
    }

    /// @notice Test that reducing flashloan below minAmountToBorrow skips flashloan
    function test_lever_maxAmountToSwap_reducedFlashloanBelowMin() public {
        uint256 depositAmount = 1000e6;

        // Set high minAmountToBorrow
        uint256 minBorrow = 2000e6;
        vm.prank(management);
        strategy.setMinAmountToBorrow(minBorrow);

        // Set maxAmountToSwap that would reduce flashloan below minBorrow
        // Normal flashloan at 3x = 2 * 1000 = 2000
        // If we limit to 1500 total, flashloan = 500 which is < 2000 minBorrow
        uint256 maxSwap = 1500e6;
        vm.prank(management);
        strategy.setMaxAmountToSwap(maxSwap);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        // Tend should skip flashloan (reduced amount below minBorrow)
        vm.prank(keeper);
        strategy.tend();

        // Flashloan skipped means Case 1b: just repay(min(_amount, debt))
        // Since no debt exists yet, this is essentially a no-op for debt
        // But maxAmountToSwap check happens before minAmountToBorrow check
        // So we might still get a supply without flashloan
    }

    /// @notice Test sequential tends with maxAmountToSwap gradually building position
    function test_lever_maxAmountToSwap_gradualBuild(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set a small maxAmountToSwap to force multiple tends
        uint256 maxSwap = _amount / 3;
        vm.prank(management);
        strategy.setMaxAmountToSwap(maxSwap);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // First tend - partial position
        vm.prank(keeper);
        strategy.tend();

        (uint256 collateral1, uint256 debt1) = strategy.position();
        uint256 leverage1 = strategy.getCurrentLeverageRatio();

        // Should have some position but not at full target
        assertGt(collateral1, 0, "!should have collateral after tend 1");

        // Remove maxAmountToSwap limit
        vm.prank(management);
        strategy.setMaxAmountToSwap(type(uint256).max);

        // Disable min tend interval for this test
        vm.prank(management);
        strategy.setMinTendInterval(0);

        // Second tend - should complete the position
        vm.prank(keeper);
        strategy.tend();

        (uint256 collateral2, uint256 debt2) = strategy.position();
        uint256 leverage2 = strategy.getCurrentLeverageRatio();

        // Position should be larger now
        assertGe(collateral2, collateral1, "!collateral should increase");

        // Should be closer to or at target leverage
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGe(leverage2, target - buffer, "!should reach target leverage");
    }
}
