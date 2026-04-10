// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {Setup} from "../../base/Setup.sol";
import {SetupPawnBrokerSIUSD} from "./Setup.sol";

contract PawnBrokerSIUSDLeverScenariosTest is
    SetupPawnBrokerSIUSD,
    LeverScenariosTest
{
    function setUp() public override(SetupPawnBrokerSIUSD, LeverScenariosTest) {
        SetupPawnBrokerSIUSD.setUp();
    }

    function setUpStrategy()
        public
        override(SetupPawnBrokerSIUSD, Setup)
        returns (address)
    {
        return SetupPawnBrokerSIUSD.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupPawnBrokerSIUSD, Setup) {
        SetupPawnBrokerSIUSD.accrueYield(_amount);
    }
}
