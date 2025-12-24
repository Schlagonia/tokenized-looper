// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {SetupLST} from "./Setup.sol";

/// @notice LST Lever Scenarios tests - inherits all tests from LeverScenariosTest, uses LST setup
contract LSTLeverScenariosTest is SetupLST, LeverScenariosTest {
    function setUp() public override(SetupLST, LeverScenariosTest) {
        SetupLST.setUp();
    }

    function setUpStrategy()
        public
        override(SetupLST, Setup)
        returns (address)
    {
        return SetupLST.setUpStrategy();
    }

    function accrueYield() public override(SetupLST, Setup) {
        SetupLST.accrueYield();
    }
}
