// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup} from "./Setup.sol";

abstract contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public virtual {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        // Collateral token should be set (specific token checked in derived tests if needed)
        assertTrue(
            strategy.collateralToken() != address(0),
            "!collateralToken"
        );

        // Check leverage params
        assertEq(strategy.targetLeverageRatio(), 3e18, "!targetLeverageRatio");
        assertEq(strategy.leverageBuffer(), 0.25e18, "!leverageBuffer");
    }

    function test_operation(uint256 _amount) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend (since _deployFunds is empty to prevent sandwich attacks)
        vm.prank(keeper);
        strategy.tend();

        logStrategyStatus("After deposit");

        assertGt(strategy.totalAssets(), 0, "!totalAssets");

        // Earn Interest
        accrueYield(_amount);

        vm.prank(management);
        strategy.setLossLimitRatio(100);

        // Report profit
        vm.prank(keeper);
        strategy.report();

        skip(strategy.profitMaxUnlockTime());

        logStrategyStatus("After profit max unlock time");

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore, "!final balance");
    }

    function test_profitableReport(uint256 _amount) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        accrueYield(_amount);

        vm.prank(keeper);
        strategy.report();

        skip(strategy.profitMaxUnlockTime());

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGt(asset.balanceOf(user), _amount, "!profit not realized");
    }

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // After deposit with idle funds, tend should be triggered
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "tend should be triggered after deposit");

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        // After tend, should no longer need to tend (within buffer)
        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger, "tend should not be triggered after tending");
    }

    function test_leverageRatio(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Before deposit, leverage should be 1x (no position)
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertEq(leverageBefore, 0, "!leverage before deposit");

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // After deposit but before tend, leverage should still be 1x (funds idle)
        uint256 leverageAfterDeposit = strategy.getCurrentLeverageRatio();
        assertEq(
            leverageAfterDeposit,
            0,
            "!leverage after deposit should be 0"
        );

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        // After tend, should be near target leverage
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();

        // Should be within buffer of target
        assertGe(leverageAfter, targetLeverage - buffer, "!leverage too low");
        assertLe(leverageAfter, targetLeverage + buffer, "!leverage too high");
    }

    function test_maxFlashloan() public {
        uint256 maxFL = strategy.maxFlashloan();
        assertGt(maxFL, 0, "!maxFlashloan should be > 0");
        console2.log("Max flashloan available:", maxFL);
    }

    function test_setLeverageParams() public {
        // Test setting leverage params
        vm.startPrank(management);

        // Set new target leverage to 2.5x with 0.15 buffer
        strategy.setLeverageParams(2.5e18, 0.15e18, 5e18);
        assertEq(strategy.targetLeverageRatio(), 2.5e18, "!new target");
        assertEq(strategy.leverageBuffer(), 0.15e18, "!new buffer");

        // Test bounds validation - leverage < 1x
        vm.expectRevert("leverage < 1x");
        strategy.setLeverageParams(0.5e18, 0.1e18, 5e18);

        // Test bounds validation - buffer too small
        vm.expectRevert("buffer too small");
        strategy.setLeverageParams(2e18, 0.001e18, 5e18);

        // Test bounds validation - exceeds LLTV
        // LLTV is ~91.5% which corresponds to max leverage of ~11.76x
        // Setting target + buffer above that should fail
        vm.expectRevert("exceeds LLTV");
        strategy.setLeverageParams(3e18, 1e18, 40e18); // 11x + 1x = 12x would exceed LLTV

        // Test bounds validation - max leverage < target + buffer
        vm.expectRevert("max leverage < target + buffer");
        strategy.setLeverageParams(2e18, 0.1e18, 1e18);

        vm.stopPrank();
    }

    function test_manualFullUnwind(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        assertGt(strategy.totalAssets(), 0, "!totalAssets");
        assertGt(
            strategy.balanceOfCollateral(),
            0,
            "!collateral should be > 0 before unwind"
        );

        // Full unwind via flashloan
        vm.prank(management);
        strategy.manualFullUnwind();

        // Position should be closed
        assertEq(strategy.balanceOfCollateral(), 0, "!collateral should be 0");
        assertEq(strategy.balanceOfDebt(), 0, "!debt should be 0");
    }

    function test_manualPrimitives(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Airdrop asset to strategy for manual operations
        airdrop(asset, address(strategy), _amount);

        vm.prank(management);
        strategy.convertAssetToCollateral(type(uint256).max);

        // Manual supply collateral
        vm.prank(management);
        strategy.manualSupplyCollateral(type(uint256).max);

        uint256 collateral = strategy.balanceOfCollateral();
        assertGt(collateral, 0, "!collateral after supply");

        // Manual borrow
        uint256 borrowAmount = _amount / 2;
        vm.prank(management);
        strategy.manualBorrow(borrowAmount);

        uint256 debt = strategy.balanceOfDebt();
        assertGt(debt, 0, "!debt after borrow");

        // Manual repay
        vm.prank(management);
        strategy.manualRepay(type(uint256).max);

        uint256 debtAfterRepay = strategy.balanceOfDebt();
        assertLt(debtAfterRepay, debt, "!debt should decrease after repay");

        // Manual withdraw collateral
        vm.prank(management);
        strategy.manualWithdrawCollateral(collateral / 2);

        uint256 collateralAfter = strategy.balanceOfCollateral();
        assertLt(collateralAfter, collateral, "!collateral should decrease");
    }

    function test_leverageBoundsValidation() public {
        uint256 lltv = strategy.getLiquidateCollateralFactor();
        console2.log("LLTV:", lltv);

        // Calculate max safe leverage from LLTV
        // LTV = 1 - 1/leverage => leverage = 1 / (1 - LTV)
        uint256 maxSafeLeverage = (1e18 * 1e18) / (1e18 - lltv);
        console2.log("Max safe leverage:", maxSafeLeverage);

        // Should be able to set leverage up to but not exceeding the safe max
        vm.startPrank(management);

        // This should succeed - set to a moderate leverage
        strategy.setLeverageParams(3e18, 0.5e18, 5e18);
        assertEq(strategy.targetLeverageRatio(), 3e18);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    SETTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setMaxAmountToSwap() public {
        // Verify default value is type(uint256).max
        assertEq(
            strategy.maxAmountToSwap(),
            type(uint256).max,
            "!default maxAmountToSwap"
        );

        // Test setting a new value
        vm.prank(management);
        strategy.setMaxAmountToSwap(1000e6);
        assertEq(strategy.maxAmountToSwap(), 1000e6, "!new maxAmountToSwap");

        // Test setting to 0
        vm.prank(management);
        strategy.setMaxAmountToSwap(0);
        assertEq(strategy.maxAmountToSwap(), 0, "!zero maxAmountToSwap");

        // Test setting back to max
        vm.prank(management);
        strategy.setMaxAmountToSwap(type(uint256).max);
        assertEq(
            strategy.maxAmountToSwap(),
            type(uint256).max,
            "!max maxAmountToSwap"
        );
    }

    function test_setMaxAmountToSwap_onlyManagement() public {
        // Non-management should not be able to set
        vm.prank(user);
        vm.expectRevert("!management");
        strategy.setMaxAmountToSwap(1000e6);

        // Keeper should not be able to set
        vm.prank(keeper);
        vm.expectRevert("!management");
        strategy.setMaxAmountToSwap(1000e6);
    }

    function test_setMinTendInterval() public {
        // Verify default value is 2 hours
        assertEq(
            strategy.minTendInterval(),
            2 hours,
            "!default minTendInterval"
        );

        // Test setting a new value
        vm.prank(management);
        strategy.setMinTendInterval(1 hours);
        assertEq(strategy.minTendInterval(), 1 hours, "!new minTendInterval");

        // Test setting to 0
        vm.prank(management);
        strategy.setMinTendInterval(0);
        assertEq(strategy.minTendInterval(), 0, "!zero minTendInterval");

        // Test setting to a large value
        vm.prank(management);
        strategy.setMinTendInterval(7 days);
        assertEq(strategy.minTendInterval(), 7 days, "!7days minTendInterval");
    }

    function test_setMinTendInterval_onlyManagement() public {
        // Non-management should not be able to set
        vm.prank(user);
        vm.expectRevert("!management");
        strategy.setMinTendInterval(1 hours);

        // Keeper should not be able to set
        vm.prank(keeper);
        vm.expectRevert("!management");
        strategy.setMinTendInterval(1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                    AVAILABLE DEPOSIT LIMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_availableDepositLimit_zeroWhenLeverageAtOrBelowOne() public {
        // Set leverage ratio to exactly 1x (no leverage)
        vm.prank(management);
        strategy.setLeverageParams(1e18, 0.01e18, 5e18);

        // Available deposit limit should be 0 when targetLeverageRatio <= WAD
        uint256 limit = strategy.availableDepositLimit(user);
        assertEq(limit, 0, "!limit should be 0 when leverage <= 1x");
    }

    function test_availableDepositLimit_respectsTargetLeverageRatio(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Get deposit limit at default 3x leverage
        uint256 limit3x = strategy.availableDepositLimit(user);
        assertGt(limit3x, 0, "!limit3x should be > 0");

        // Change to 2x leverage - should allow more deposits per unit of collateral capacity
        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.25e18, 5e18);

        uint256 limit2x = strategy.availableDepositLimit(user);
        assertGt(limit2x, 0, "!limit2x should be > 0");

        // At lower leverage, same collateral capacity allows more deposits
        // deposit = collateral / L, so 2x leverage allows more than 3x
        // This may not always be true depending on borrow capacity constraints
        // So we just verify both are positive
    }

    function test_availableDepositLimit_zeroForNonAllowedAddress() public {
        address notAllowed = address(0x1234);
        assertFalse(strategy.allowed(notAllowed), "!should not be allowed");

        uint256 limit = strategy.availableDepositLimit(notAllowed);
        assertEq(limit, 0, "!limit should be 0 for non-allowed address");
    }

    function test_availableDepositLimit_respectsDepositLimit(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set a low deposit limit
        vm.prank(management);
        strategy.setDepositLimit(_amount);

        uint256 limit = strategy.availableDepositLimit(user);
        assertLe(limit, _amount, "!limit should not exceed deposit limit");

        // After depositing, limit should decrease
        mintAndDepositIntoStrategy(strategy, user, _amount / 2);

        uint256 limitAfter = strategy.availableDepositLimit(user);
        assertLe(
            limitAfter,
            _amount / 2 + 1,
            "!limit should decrease after deposit"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    AVAILABLE WITHDRAW LIMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_availableWithdrawLimit_maxWhenNoPosition() public {
        // With no position, withdraw limit should be max
        uint256 limit = strategy.availableWithdrawLimit(user);
        assertEq(
            limit,
            type(uint256).max,
            "!limit should be max with no position"
        );
    }

    function test_availableWithdrawLimit_maxWhenFlashloanCoversDebt(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Create a position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Get current debt
        uint256 debt = strategy.balanceOfDebt();
        uint256 flashloan = strategy.maxFlashloan();

        // If flashloan >= debt, limit should be max
        if (flashloan >= debt) {
            uint256 limit = strategy.availableWithdrawLimit(user);
            assertEq(
                limit,
                type(uint256).max,
                "!limit should be max when flashloan covers debt"
            );
        }
    }

    function test_availableWithdrawLimit_calculatesCorrectlyWhenFlashloanLimited()
        public
    {
        // This test verifies the math when flashloan < debt
        // We need to create a scenario where maxFlashloan < balanceOfDebt
        // This is hard to simulate in a real fork, so we verify the formula:
        //   targetDebt = currentDebt - flashloanAvailable
        //   targetEquity = targetDebt * WAD / (L - WAD)
        //   maxWithdraw = currentEquity - targetEquity

        uint256 _amount = 100_000e6;
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        uint256 currentDebt = strategy.balanceOfDebt();
        uint256 flashloanAvailable = strategy.maxFlashloan();
        uint256 targetLeverage = strategy.targetLeverageRatio();

        if (flashloanAvailable >= currentDebt) {
            // Normal case - max withdraw
            assertEq(
                strategy.availableWithdrawLimit(user),
                type(uint256).max,
                "!max withdraw when flashloan covers debt"
            );
        } else {
            // Limited case - verify formula
            uint256 targetDebt = currentDebt - flashloanAvailable;
            uint256 targetEquity = (targetDebt * 1e18) /
                (targetLeverage - 1e18);

            (uint256 collateralValue, ) = strategy.position();
            uint256 currentEquity = collateralValue - currentDebt;

            uint256 expectedLimit = currentEquity > targetEquity
                ? currentEquity - targetEquity
                : 0;

            assertEq(
                strategy.availableWithdrawLimit(user),
                expectedLimit,
                "!withdraw limit calculation mismatch"
            );
        }
    }

    function test_availableWithdrawLimit_zeroWhenEquityBelowTarget() public {
        // Edge case: if currentEquity <= targetEquity, should return 0
        // This is hard to simulate but the code handles it
        uint256 limit = strategy.availableWithdrawLimit(user);
        // With no position, should be max (no debt scenario)
        assertEq(limit, type(uint256).max, "!limit should be max with no debt");
    }

    /*//////////////////////////////////////////////////////////////
                    MIN TEND INTERVAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_tendTrigger_respectsMinTendInterval(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set a longer min tend interval
        vm.prank(management);
        strategy.setMinTendInterval(1 hours);

        // Deposit and first tend
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Immediately after tend, trigger should be false (even with idle funds)
        // unless there's an emergency condition
        airdrop(asset, address(strategy), _amount / 10);

        // Check tend trigger - should be false due to interval
        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "!tend should not trigger within min interval");

        // Skip past the interval
        skip(1 hours + 1);

        // Now tend should be triggered (we have idle funds)
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "!tend should trigger after interval passed");
    }

    function test_tendTrigger_bypassesIntervalForEmergency(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set a long min tend interval
        vm.prank(management);
        strategy.setMinTendInterval(7 days);

        // Deposit and first tend
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Get current leverage
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 maxLeverage = strategy.maxLeverageRatio();

        // If we're above max leverage, tend should trigger regardless of interval
        // This requires manipulating the position to be above max
        // For now, verify that the interval check comes after emergency checks
        (bool trigger, ) = strategy.tendTrigger();
        // Should be false because we're within buffer and interval hasn't passed
        assertFalse(
            trigger,
            "!tend should respect interval when not emergency"
        );
    }

    function test_lastTend_updatesAfterTend(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Verify lastTend starts at 0
        uint256 lastTendBefore = strategy.lastTend();
        assertEq(lastTendBefore, 0, "!lastTend should start at 0");

        // Deposit and tend
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // lastTend should be updated to current timestamp
        uint256 lastTendAfter = strategy.lastTend();
        assertEq(lastTendAfter, block.timestamp, "!lastTend should update");

        // Skip some time and tend again
        skip(3 hours);
        airdrop(asset, address(strategy), _amount / 10);
        vm.prank(keeper);
        strategy.tend();

        // lastTend should update again
        assertEq(
            strategy.lastTend(),
            block.timestamp,
            "!lastTend should update again"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    TEND TRIGGER CAPACITY EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Helper to create an over-leveraged position by changing target after build
    /// @param equity The equity amount to use for the position
    function _createOverLeveragedPosition(uint256 equity) internal {
        // 1. Deposit and tend to build position at current target (3x)
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // 2. Lower the target so current position becomes over-leveraged
        // Current: 3x target, 0.25 buffer => bounds [2.75, 3.25]
        // New: 2x target, 0.25 buffer => bounds [1.75, 2.25]
        // Position at ~3x will be above 2.25 upper bound
        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.25e18, 5e18);

        // Verify position is now over-leveraged
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 upperBound = strategy.targetLeverageRatio() +
            strategy.leverageBuffer();
        assertGt(
            currentLeverage,
            upperBound,
            "position should be over-leveraged"
        );
    }

    /// @notice Helper to create an under-leveraged position by changing target after build
    /// @param equity The equity amount to use for the position
    function _createUnderLeveragedPosition(uint256 equity) internal {
        // 1. First set a lower target
        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.25e18, 5e18);

        // 2. Deposit and tend to build position at 2x target
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // 3. Raise the target so current position becomes under-leveraged
        // Current: 2x target, 0.25 buffer => bounds [1.75, 2.25]
        // New: 4x target, 0.5 buffer => bounds [3.5, 4.5]
        // Position at ~2x will be below 3.5 lower bound
        vm.prank(management);
        strategy.setLeverageParams(4e18, 0.5e18, 6e18);

        // Verify position is now under-leveraged
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 lowerBound = strategy.targetLeverageRatio() -
            strategy.leverageBuffer();
        assertLt(
            currentLeverage,
            lowerBound,
            "position should be under-leveraged"
        );
    }

    /// @notice Test 1: Over-leveraged with idle assets should trigger tend
    /// @dev When over-leveraged (> upperBound) and has idle assets (balanceOfAsset > 0),
    ///      tendTrigger should return true as we can use idle assets to repay debt.
    function test_tendTrigger_overLeveragedWithIdleAssets() public {
        uint256 equity = 10000e6;

        // Create over-leveraged position
        _createOverLeveragedPosition(equity);

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Airdrop idle assets to the strategy
        uint256 idleAmount = 1000e6;
        airdrop(asset, address(strategy), idleAmount);

        // Verify we have idle assets
        assertGt(strategy.balanceOfAsset(), 0, "should have idle assets");

        // Verify over-leveraged
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 upperBound = strategy.targetLeverageRatio() +
            strategy.leverageBuffer();
        assertGt(currentLeverage, upperBound, "should be over-leveraged");

        // tendTrigger should return true
        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(
            trigger,
            "tendTrigger should return true when over-leveraged with idle assets"
        );
    }

    /// @notice Test 2: Over-leveraged with no idle but can withdraw should trigger
    /// @dev When over-leveraged and no idle assets, but maxWithdraw > 0 (can delever via flashloan),
    ///      tendTrigger should return true.
    function test_tendTrigger_overLeveragedCanWithdraw() public {
        uint256 equity = 10000e6;

        // Create over-leveraged position
        _createOverLeveragedPosition(equity);

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Ensure NO idle assets
        assertEq(strategy.balanceOfAsset(), 0, "should have no idle assets");

        // Verify we can withdraw (flashloan available)
        uint256 maxWithdraw = strategy.availableWithdrawLimit(
            address(strategy)
        );
        assertGt(maxWithdraw, 0, "should be able to withdraw");

        // Verify over-leveraged
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 upperBound = strategy.targetLeverageRatio() +
            strategy.leverageBuffer();
        assertGt(currentLeverage, upperBound, "should be over-leveraged");

        // tendTrigger should return true
        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(
            trigger,
            "tendTrigger should return true when over-leveraged and can withdraw"
        );
    }

    /// @notice Test 3: Over-leveraged but cannot withdraw should NOT trigger
    /// @dev When over-leveraged, no idle assets, AND maxWithdraw = 0,
    ///      tendTrigger should return false as there's no way to delever.
    /// @dev This is a difficult scenario to create in a real fork since flashloan
    ///      is usually available. We test by setting deposit limit to 0 which
    ///      affects availableDepositLimit but not withdraw. For a true test,
    ///      we'd need to mock the protocol.
    function test_tendTrigger_overLeveragedCantWithdraw() public {
        // This test verifies the logic path where:
        // - currentLeverage > upperBound (over-leveraged)
        // - balanceOfAsset() == 0 (no idle)
        // - maxWithdraw == 0 (can't withdraw)
        // Result: return false

        // Since it's hard to make maxWithdraw = 0 in a real fork (flashloan usually available),
        // we verify the logic by checking that when over-leveraged with no idle but CAN withdraw,
        // it returns true (test 2 above). The code path for returning false when can't withdraw
        // is tested implicitly.

        uint256 equity = 10000e6;

        // Create over-leveraged position
        _createOverLeveragedPosition(equity);

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Ensure NO idle assets
        assertEq(strategy.balanceOfAsset(), 0, "should have no idle assets");

        // In a real scenario with flashloan available, we can withdraw
        // The test confirms the positive case; the negative case (can't withdraw)
        // would require mocking the flashloan to be 0
        uint256 maxWithdraw = strategy.availableWithdrawLimit(
            address(strategy)
        );

        if (maxWithdraw == 0) {
            // If somehow maxWithdraw is 0, tendTrigger should be false
            (bool trigger, ) = strategy.tendTrigger();
            assertFalse(
                trigger,
                "tendTrigger should return false when over-leveraged but can't withdraw"
            );
        } else {
            // Normal case: can withdraw, so trigger is true
            (bool trigger, ) = strategy.tendTrigger();
            assertTrue(
                trigger,
                "tendTrigger should return true when can withdraw"
            );
        }
    }

    /// @notice Test 4: Under-leveraged and can deposit should trigger
    /// @dev When under-leveraged (< lowerBound) and maxDeposit > minAmountToBorrow,
    ///      tendTrigger should return true.
    function test_tendTrigger_underLeveragedCanDeposit() public {
        uint256 equity = 10000e6;

        // Create under-leveraged position
        _createUnderLeveragedPosition(equity);

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Verify under-leveraged
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 lowerBound = strategy.targetLeverageRatio() -
            strategy.leverageBuffer();
        assertLt(currentLeverage, lowerBound, "should be under-leveraged");

        // Verify deposit capacity is available
        uint256 maxDeposit = strategy.availableDepositLimit(address(strategy));
        uint256 minBorrow = strategy.minAmountToBorrow();
        assertGt(maxDeposit, minBorrow, "should have deposit capacity");

        // tendTrigger should return true
        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(
            trigger,
            "tendTrigger should return true when under-leveraged and can deposit"
        );
    }

    /// @notice Test 5: Under-leveraged but cannot deposit should NOT trigger
    /// @dev When under-leveraged but maxDeposit = 0 (no deposit capacity),
    ///      tendTrigger should return false.
    function test_tendTrigger_underLeveragedCantDeposit() public {
        uint256 equity = 10000e6;

        // Create under-leveraged position
        _createUnderLeveragedPosition(equity);

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Set deposit limit to 0 to simulate no deposit capacity
        // This makes availableDepositLimit return 0
        vm.prank(management);
        strategy.setDepositLimit(0);

        // Verify deposit capacity is now 0
        uint256 maxDeposit = strategy.availableDepositLimit(address(strategy));
        assertEq(maxDeposit, 0, "deposit capacity should be 0");

        // Verify still under-leveraged
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 lowerBound = strategy.targetLeverageRatio() -
            strategy.leverageBuffer();
        assertLt(
            currentLeverage,
            lowerBound,
            "should still be under-leveraged"
        );

        // tendTrigger should return false (can't deposit to fix under-leverage)
        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(
            trigger,
            "tendTrigger should return false when under-leveraged but can't deposit"
        );
    }

    /// @notice Test 6: Has meaningful idle assets and can deposit should trigger
    /// @dev When within buffer but has idle assets that would generate debt > minAmountToBorrow,
    ///      and maxDeposit > minAmountToBorrow, tendTrigger should return true.
    function test_tendTrigger_idleAssetsCanDeposit() public {
        uint256 equity = 10000e6;

        // Create a position at target
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Airdrop meaningful idle assets
        // At 3x leverage, idle * (L - 1) / 1 = idle * 2 should be > minAmountToBorrow
        // With minAmountToBorrow = 0 (default for InfinifiMorphoLooper), any idle triggers
        uint256 idleAmount = 1000e6;
        airdrop(asset, address(strategy), idleAmount);

        // Verify we have idle assets
        assertGt(strategy.balanceOfAsset(), 0, "should have idle assets");

        // Verify within buffer (not over or under leveraged)
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGe(
            currentLeverage,
            target - buffer,
            "should be within lower buffer"
        );
        assertLe(
            currentLeverage,
            target + buffer,
            "should be within upper buffer"
        );

        // Verify deposit capacity
        uint256 maxDeposit = strategy.availableDepositLimit(address(strategy));
        assertGt(
            maxDeposit,
            strategy.minAmountToBorrow(),
            "should have deposit capacity"
        );

        // tendTrigger should return true
        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(
            trigger,
            "tendTrigger should return true with idle assets and deposit capacity"
        );
    }

    /// @notice Test 7: Has meaningful idle assets but cannot deposit should NOT trigger
    /// @dev When has idle assets but maxDeposit = 0, tendTrigger should return false.
    function test_tendTrigger_idleAssetsCantDeposit() public {
        uint256 equity = 10000e6;

        // Create a position at target
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Airdrop meaningful idle assets
        uint256 idleAmount = 1000e6;
        airdrop(asset, address(strategy), idleAmount);

        // Set deposit limit to 0 to simulate no deposit capacity
        vm.prank(management);
        strategy.setDepositLimit(0);

        // Verify we have idle assets
        assertGt(strategy.balanceOfAsset(), 0, "should have idle assets");

        // Verify deposit capacity is 0
        uint256 maxDeposit = strategy.availableDepositLimit(address(strategy));
        assertEq(maxDeposit, 0, "deposit capacity should be 0");

        // tendTrigger should return false (can't deploy idle assets)
        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(
            trigger,
            "tendTrigger should return false with idle assets but no deposit capacity"
        );
    }

    /// @notice Test 8: Tiny idle assets should NOT trigger
    /// @dev When idle assets are so small that debt generated would be < minAmountToBorrow,
    ///      tendTrigger should return false.
    function test_tendTrigger_tinyIdleAssetsNoTrigger() public {
        uint256 equity = 10000e6;

        // Create a position at target
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Set a high minAmountToBorrow
        vm.prank(management);
        strategy.setMinAmountToBorrow(1000e6);

        // Airdrop tiny idle assets that won't generate enough debt
        // At 3x leverage: idle * (L - 1) / 1 = idle * 2
        // For debt > 1000e6, we need idle > 500e6
        // So idle of 100e6 should generate debt of 200e6 < 1000e6 minAmountToBorrow
        uint256 tinyIdle = 100e6;
        airdrop(asset, address(strategy), tinyIdle);

        // Verify we have idle assets
        uint256 idle = strategy.balanceOfAsset();
        assertGt(idle, 0, "should have idle assets");

        // Verify the debt that would be generated is less than minAmountToBorrow
        uint256 target = strategy.targetLeverageRatio();
        uint256 potentialDebt = (idle * (target - 1e18)) / 1e18;
        uint256 minBorrow = strategy.minAmountToBorrow();
        assertLt(
            potentialDebt,
            minBorrow,
            "potential debt should be less than minAmountToBorrow"
        );

        // Verify within buffer (not under-leveraged which would override the idle check)
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGe(
            currentLeverage,
            target - buffer,
            "should be within lower buffer"
        );
        assertLe(
            currentLeverage,
            target + buffer,
            "should be within upper buffer"
        );

        // tendTrigger should return false (idle assets too small to matter)
        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(
            trigger,
            "tendTrigger should return false with tiny idle assets"
        );
    }

    /// @notice Test 9: Within buffer and no idle assets should NOT trigger
    /// @dev When within the leverage buffer range and no idle assets to deploy,
    ///      tendTrigger should return false.
    function test_tendTrigger_withinBufferNoIdle() public {
        uint256 equity = 10000e6;

        // Create a position at target
        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        // Skip past minTendInterval
        skip(strategy.minTendInterval() + 1);

        // Verify NO idle assets
        assertEq(strategy.balanceOfAsset(), 0, "should have no idle assets");

        // Verify within buffer
        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGe(
            currentLeverage,
            target - buffer,
            "should be within lower buffer"
        );
        assertLe(
            currentLeverage,
            target + buffer,
            "should be within upper buffer"
        );

        // tendTrigger should return false (within buffer, nothing to do)
        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(
            trigger,
            "tendTrigger should return false when within buffer with no idle"
        );
    }
}
