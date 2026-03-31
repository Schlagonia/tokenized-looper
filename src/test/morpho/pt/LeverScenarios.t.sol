// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {SetupPT} from "./Setup.sol";

/// @notice PT LeverScenarios tests - inherits all tests from LeverScenariosTest, uses PT setup
contract PTLeverScenariosTest is SetupPT, LeverScenariosTest {
    function setUp() public override(SetupPT, LeverScenariosTest) {
        SetupPT.setUp();
    }

    function setUpStrategy() public override(SetupPT, Setup) returns (address) {
        return SetupPT.setUpStrategy();
    }

    function accrueYield(uint256 _amount) public override(SetupPT, Setup) {
        SetupPT.accrueYield(_amount);
    }

    function test_lever_noPosition_exactAmount_100_revertsOnPendleLiquidity()
        public
    {
        uint256 amount = 100e6;

        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.expectRevert(bytes("insufficient liquidity"));
        vm.prank(keeper);
        strategy.tend();
    }

    function test_lever_noPosition_exactAmount_50k_revertsOnPendleLiquidity()
        public
    {
        uint256 amount = 50_000e6;

        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.expectRevert(bytes("Slippage: search range overflow"));
        vm.prank(keeper);
        strategy.tend();
    }
}
