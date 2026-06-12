// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {Setup} from "../../base/Setup.sol";
import {SetupPawnBrokerSTCUSD} from "./Setup.sol";

contract PawnBrokerSTCUSDLeverScenariosTest is
    SetupPawnBrokerSTCUSD,
    LeverScenariosTest
{
    function setUp()
        public
        override(SetupPawnBrokerSTCUSD, LeverScenariosTest)
    {
        SetupPawnBrokerSTCUSD.setUp();
    }

    function setUpStrategy()
        public
        override(SetupPawnBrokerSTCUSD, Setup)
        returns (address)
    {
        return SetupPawnBrokerSTCUSD.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupPawnBrokerSTCUSD, Setup) {
        SetupPawnBrokerSTCUSD.accrueYield(_amount);
    }
}
