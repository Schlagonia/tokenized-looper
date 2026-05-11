// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {SetupSparkLendLST} from "./Setup.sol";

/// @notice SparkLend LST Lever Scenarios tests - inherits all tests from LeverScenariosTest, uses SparkLend LST setup
contract SparkLendLSTLeverScenariosTest is
    SetupSparkLendLST,
    LeverScenariosTest
{
    function setUp() public override(SetupSparkLendLST, LeverScenariosTest) {
        SetupSparkLendLST.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSparkLendLST, Setup)
        returns (address)
    {
        return SetupSparkLendLST.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSparkLendLST, Setup) {
        SetupSparkLendLST.accrueYield(_amount);
    }

    /// @notice Override base test - SparkLend wstETH has 81% LLTV (~5.26x max leverage)
    /// Base test uses 6x which exceeds LLTV, so we use 5x instead
    function test_lever_afterIncreasingTargetLeverage(
        uint256 _amount
    ) public override {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // 1. Setup: Lower initial target
        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.3e18, 4e18);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertGe(leverageBefore, 2e18 - 0.3e18, "should be at 2x target");
        assertLe(leverageBefore, 2e18 + 0.3e18, "should be at 2x target");

        // 2. Increase target leverage (use 4x/5x which is within SparkLend's 81% LLTV)
        vm.prank(management);
        strategy.setLeverageParams(4e18, 0.5e18, 5e18);

        // 3. Now position is under-leveraged
        uint256 currentLev = strategy.getCurrentLeverageRatio();
        assertLt(
            currentLev,
            4e18 - 0.5e18,
            "should be under-leveraged vs new target"
        );

        // 4. Tend should lever up to new target
        vm.prank(keeper);
        strategy.tend();

        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        assertGe(leverageAfter, 4e18 - 0.5e18, "should be near 4x");
        assertLe(leverageAfter, 4e18 + 0.5e18, "should be near 4x");
        assertGt(leverageAfter, leverageBefore, "leverage should increase");
    }

    /// @notice SparkLend debt indexes can add one wei while the capped deleveraging transaction executes.
    function test_lever_overLeveraged_maxAmountToSwap_capsDeleverage(
        uint256 equityAmount
    ) public override {
        vm.assume(equityAmount > minFuzzAmount && equityAmount < maxFuzzAmount);

        (
            uint256 collateralBefore,
            uint256 debtBefore
        ) = _setupOverLeveragedPosition(equityAmount);

        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertGt(leverageBefore, target + buffer, "should be over-leveraged");

        uint256 currentEquity = collateralBefore - debtBefore;
        (, uint256 targetDebt) = _getTargetPosition(currentEquity);
        uint256 debtToRepay = debtBefore - targetDebt;
        vm.assume(debtToRepay > 0);

        uint256 maxSwap = debtToRepay / 4;
        vm.assume(maxSwap > 0);

        vm.prank(management);
        strategy.setMaxAmountToSwap(maxSwap);

        vm.prank(keeper);
        strategy.tend();

        uint256 debtAfter = strategy.balanceOfDebt();
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        uint256 debtReduction = debtBefore - debtAfter;

        assertGt(debtReduction, 0, "should repay some debt");
        assertLe(
            debtReduction,
            maxSwap + 1,
            "delever should respect maxAmountToSwap"
        );
        assertLt(leverageAfter, leverageBefore, "leverage should improve");
        assertGt(
            leverageAfter,
            target + buffer,
            "position should still be over target"
        );
    }
}
