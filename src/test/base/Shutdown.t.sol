pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup} from "./Setup.sol";

abstract contract ShutdownTest is Setup {
    // Allow tiny residual collateral after full unwind due to rounding/swap dust.
    uint256 internal constant UNWIND_COLLATERAL_DUST_BPS = 1; // 0.01%
    uint256 internal constant MIN_UNWIND_COLLATERAL_DUST = 1;

    function setUp() public virtual override {
        super.setUp();
    }

    function _maxUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure virtual returns (uint256) {
        uint256 relativeDust = collateralBeforeUnwind /
            (10_000 / UNWIND_COLLATERAL_DUST_BPS);
        return
            relativeDust > MIN_UNWIND_COLLATERAL_DUST
                ? relativeDust
                : MIN_UNWIND_COLLATERAL_DUST;
    }

    function test_shutdownCanWithdraw(uint256 _amount) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend
        _keeperTendAndSettle();

        assertGt(strategy.totalAssets(), 0, "!totalAssets");

        // Earn Interest
        accrueYield(_amount);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertGt(strategy.totalAssets(), 0, "!totalAssets");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);
        _prepareExitSwapRoute();
        bytes memory swapData = _simulateRedeemSwapData(_amount);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user, swapData);

        assertApproxEqRel(
            asset.balanceOf(user),
            balanceBefore + _amount,
            0.01e18
        );
    }

    function test_emergencyWithdraw_maxUint(uint256 _amount) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend and settle the auction so position is built
        _keeperTendAndSettle();

        // Earn Interest
        accrueYield(_amount);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // should be able to pass uint 256 max and not revert.
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);
        _settleActiveAuction();

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertApproxEqRel(
            asset.balanceOf(user),
            balanceBefore + _amount,
            0.01e18
        );
    }

    // TODO: Add tests for any emergency function added.

    /*//////////////////////////////////////////////////////////////
                        IDLE MODE TESTS (targetLeverageRatio == 0)
    //////////////////////////////////////////////////////////////*/

    function test_idleMode_setLeverageParams() public {
        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        assertEq(strategy.targetLeverageRatio(), 0, "!target should be 0");
        assertEq(strategy.leverageBuffer(), 0, "!buffer should be 0");
        assertEq(strategy.maxLeverageRatio(), 5e18, "!maxLeverageRatio");
    }

    function test_idleMode_rejectsNonZeroBuffer() public {
        vm.prank(management);
        vm.expectRevert(bytes("buf0"));
        strategy.setLeverageParams(0, 0.1e18, 5e18);
    }

    function test_idleMode_unwindsPosition(uint256 _amount) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Setup leveraged position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        _keeperTendAndSettle();

        // Verify position exists
        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();
        assertGt(collateralBeforeUnwind, 0, "!collateral before");
        assertGt(strategy.balanceOfDebt(), 0, "!debt before");

        // Set idle mode
        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);
        _prepareExitSwapRoute();
        bytes memory swapData = _simulateRedeemSwapData(_amount);

        vm.prank(user);
        strategy.redeem(_amount, address(strategy), user, swapData);

        // Verify position is fully unwound
        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );
    }

    function test_idleMode_tendTriggerFalseAfterUnwind(
        uint256 _amount
    ) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Setup leveraged position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        _keeperTendAndSettle();
        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();

        // Set idle mode and unwind back into loose asset held on the strategy.
        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);
        _prepareExitSwapRoute();
        bytes memory swapData = _simulateRedeemSwapData(_amount);

        vm.prank(user);
        strategy.redeem(_amount, address(strategy), user, swapData);

        // Verify position is unwound
        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );

        // After full unwind in idle mode, tendTrigger should be FALSE
        // - getCurrentLeverageRatio() returns 0 when no position
        // - Idle mode check: currentLeverage > 0 → false → no tend needed
        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(
            trigger,
            "!tendTrigger should be false after full unwind in idle mode"
        );
    }

    function test_idleMode_tendTriggerTrueWithDebt(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Setup leveraged position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        _keeperTendAndSettle();

        // Verify position has debt
        assertGt(strategy.balanceOfDebt(), 0, "!debt should exist");

        // Set idle mode (don't tend yet)
        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        // Skip past the minTendInterval so tendTrigger can check leverage conditions
        skip(strategy.minTendInterval() + 1);

        // Verify tend trigger is true (still has debt to unwind)
        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "!tendTrigger should be true with debt");
    }

    function test_idleMode_staysIdle(uint256 _amount) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Setup leveraged position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        _keeperTendAndSettle();
        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();

        // Set idle mode and unwind back into loose asset held on the strategy.
        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);
        _prepareExitSwapRoute();
        bytes memory swapData = _simulateRedeemSwapData(_amount);

        vm.prank(user);
        strategy.redeem(_amount, address(strategy), user, swapData);

        // Verify position is unwound
        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );

        // In idle mode, availableDepositLimit() returns 0 because targetLeverageRatio <= WAD
        // This prevents new deposits from being accepted
        uint256 depositLimitInIdleMode = strategy.availableDepositLimit(user);
        assertEq(
            depositLimitInIdleMode,
            0,
            "!deposit limit should be 0 in idle mode"
        );

        // Skip past minTendInterval for tend to work
        skip(strategy.minTendInterval() + 1);

        // Note: In idle mode (targetLeverageRatio = 0), calling tend() will hit CASE 3
        // which supplies collateral without borrowing. This is the expected behavior:
        // assets are converted to collateral but no leverage is applied.
        _keeperTendAndSettle();

        // Verify NO DEBT (key assertion for idle mode)
        assertEq(
            strategy.balanceOfDebt(),
            0,
            "!debt should still be 0 in idle mode"
        );

        // Collateral may be non-zero as CASE 3 supplies collateral without leverage
        // This is acceptable behavior - assets are deployed but not leveraged
        // The key invariant is that debt = 0 (no borrowing in idle mode)
    }

    function test_idleMode_canReenableLeverage(uint256 _amount) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Setup leveraged position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        _keeperTendAndSettle();
        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();

        // Set idle mode and unwind back into loose asset held on the strategy.
        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);
        _prepareExitSwapRoute();
        bytes memory swapData = _simulateRedeemSwapData(_amount);

        vm.prank(user);
        strategy.redeem(_amount, address(strategy), user, swapData);

        // Verify position is unwound
        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );

        // Re-enable leverage (3x with 0.5x buffer)
        vm.prank(management);
        strategy.setLeverageParams(3e18, 0.5e18, 5e18);

        // Rebuild position via tend
        skip(strategy.minTendInterval() + 1);
        _keeperTendAndSettle();

        // Verify position is rebuilt
        assertGt(
            strategy.balanceOfCollateral(),
            0,
            "!collateral should be > 0"
        );
        assertGt(strategy.balanceOfDebt(), 0, "!debt should be > 0");

        // Verify leverage is near target
        uint256 leverage = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGe(leverage, target - buffer, "!leverage too low");
        assertLe(leverage, target + buffer, "!leverage too high");
    }
}
