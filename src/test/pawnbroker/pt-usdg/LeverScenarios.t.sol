// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {Setup} from "../../base/Setup.sol";
import {SetupPawnBrokerPTUSDG} from "./Setup.sol";

contract PawnBrokerPTUSDGLeverScenariosTest is
    SetupPawnBrokerPTUSDG,
    LeverScenariosTest
{
    function setUp()
        public
        override(SetupPawnBrokerPTUSDG, LeverScenariosTest)
    {
        SetupPawnBrokerPTUSDG.setUp();
    }

    function setUpStrategy()
        public
        override(SetupPawnBrokerPTUSDG, Setup)
        returns (address)
    {
        return SetupPawnBrokerPTUSDG.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupPawnBrokerPTUSDG, Setup) {
        SetupPawnBrokerPTUSDG.accrueYield(_amount);
    }
}
