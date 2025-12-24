// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {SetupPTArb} from "./Setup.sol";

contract PTArbLeverScenariosTest is SetupPTArb, LeverScenariosTest {
    function setUp() public override(SetupPTArb, LeverScenariosTest) {
        SetupPTArb.setUp();
    }

    function setUpStrategy()
        public
        override(SetupPTArb, Setup)
        returns (address)
    {
        return SetupPTArb.setUpStrategy();
    }

    function accrueYield() public override(SetupPTArb, Setup) {
        SetupPTArb.accrueYield();
    }
}
