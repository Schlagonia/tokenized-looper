// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {SetupAaveLST} from "./Setup.sol";

/// @notice Aave LST Lever Scenarios tests - inherits all tests from LeverScenariosTest, uses Aave LST setup
contract AaveLSTLeverScenariosTest is SetupAaveLST, LeverScenariosTest {
    function setUp() public override(SetupAaveLST, LeverScenariosTest) {
        SetupAaveLST.setUp();
    }

    function setUpStrategy()
        public
        override(SetupAaveLST, Setup)
        returns (address)
    {
        return SetupAaveLST.setUpStrategy();
    }

    function accrueYield() public override(SetupAaveLST, Setup) {
        SetupAaveLST.accrueYield();
    }

    /// @notice Override base test - Aave wstETH has 81% LLTV (~5.26x max leverage)
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

        // 2. Increase target leverage (use 4x/5x which is within Aave's 81% LLTV)
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
}
