// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {ShutdownTest} from "../../base/Shutdown.t.sol";
import {SetupAavesUSDeUSDC, TestableSUSDeAaveLooper} from "./Setup.sol";

contract AavesUSDeUSDCShutdownTest is SetupAavesUSDeUSDC, ShutdownTest {
    uint256 internal constant SUSDE_UNWIND_DUST_BPS = 5; // 0.05%

    function setUp() public override(SetupAavesUSDeUSDC, ShutdownTest) {
        SetupAavesUSDeUSDC.setUp();
    }

    function setUpStrategy()
        public
        override(SetupAavesUSDeUSDC, Setup)
        returns (address)
    {
        return SetupAavesUSDeUSDC.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupAavesUSDeUSDC, Setup) {
        SetupAavesUSDeUSDC.accrueYield(_amount);
    }

    function _simulateExitSwapData(
        uint256 _assetAmountNeeded
    )
        internal
        view
        override(SetupAavesUSDeUSDC, Setup)
        returns (bytes memory)
    {
        return SetupAavesUSDeUSDC._simulateExitSwapData(_assetAmountNeeded);
    }

    function _prepareExitSwapRoute()
        internal
        override(SetupAavesUSDeUSDC, Setup)
    {
        SetupAavesUSDeUSDC._prepareExitSwapRoute();
    }

    function _maxUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure override returns (uint256) {
        uint256 relativeDust = collateralBeforeUnwind /
            (10_000 / SUSDE_UNWIND_DUST_BPS);
        return
            relativeDust > MIN_UNWIND_COLLATERAL_DUST
                ? relativeDust
                : MIN_UNWIND_COLLATERAL_DUST;
    }

    function _manualFullUnwindWithSwapData() internal {
        _prepareExitSwapRoute();
        bytes memory swapData = _simulateManualFullUnwindSwapData();

        vm.prank(emergencyAdmin);
        TestableSUSDeAaveLooper(payable(address(strategy))).manualFullUnwind(
            swapData
        );
    }

    function test_shutdownCanWithdraw(uint256 _amount) public override {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        _keeperTendAndSettle();
        accrueYield(_amount);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        uint256 balanceBefore = asset.balanceOf(user);
        _manualFullUnwindWithSwapData();

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertApproxEqRel(
            asset.balanceOf(user),
            balanceBefore + _amount,
            0.01e18
        );
    }

    function test_idleMode_unwindsPosition(uint256 _amount) public override {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        _keeperTendAndSettle();

        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();
        assertGt(collateralBeforeUnwind, 0, "!collateral before");
        assertGt(strategy.balanceOfDebt(), 0, "!debt before");

        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);
        _manualFullUnwindWithSwapData();

        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );
    }

    function test_idleMode_tendTriggerFalseAfterUnwind(
        uint256 _amount
    ) public override {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        _keeperTendAndSettle();
        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();

        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);
        _manualFullUnwindWithSwapData();

        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );

        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "!tendTrigger should be false after full unwind in idle mode");
    }

    function test_idleMode_staysIdle(uint256 _amount) public override {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        _keeperTendAndSettle();
        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();

        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);
        _manualFullUnwindWithSwapData();

        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );

        assertEq(
            strategy.availableDepositLimit(user),
            0,
            "!deposit limit should be 0 in idle mode"
        );

        skip(strategy.minTendInterval() + 1);
        _keeperTendAndSettle();

        assertEq(strategy.balanceOfDebt(), 0, "!debt should still be 0 in idle mode");
    }

    function test_idleMode_canReenableLeverage(uint256 _amount) public override {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        _keeperTendAndSettle();
        uint256 collateralBeforeUnwind = strategy.balanceOfCollateral();

        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);
        _manualFullUnwindWithSwapData();

        assertLe(
            strategy.balanceOfCollateral(),
            _maxUnwindCollateralDust(collateralBeforeUnwind),
            "!collateral dust too high"
        );

        vm.prank(management);
        strategy.setLeverageParams(3e18, 0.5e18, 5e18);

        skip(strategy.minTendInterval() + 1);
        _keeperTendAndSettle();

        assertGt(strategy.balanceOfCollateral(), 0, "!collateral should be > 0");
        assertGt(strategy.balanceOfDebt(), 0, "!debt should be > 0");

        uint256 leverage = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGe(leverage, target - buffer, "!leverage too low");
        assertLe(leverage, target + buffer, "!leverage too high");
    }
}
