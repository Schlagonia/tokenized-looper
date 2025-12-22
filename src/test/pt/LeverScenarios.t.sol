// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../base/Setup.sol";
import {LeverScenariosTest} from "../base/LeverScenarios.t.sol";
import {SetupPT} from "./Setup.sol";

/// @notice PT LeverScenarios tests - inherits all tests from LeverScenariosTest, uses PT setup
contract PTLeverScenariosTest is SetupPT, LeverScenariosTest {
    function setUp() public override(SetupPT, LeverScenariosTest) {
        SetupPT.setUp();
        maxFuzzAmount = 50_000e6;
    }

    function setUpStrategy() public override(SetupPT, Setup) returns (address) {
        return SetupPT.setUpStrategy();
    }

    function accrueYield() public override(SetupPT, Setup) {
        SetupPT.accrueYield();
    }
}
