// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {SetupSUSDePYUSD} from "./Setup.sol";

contract sUSDePYUSDMorphoLeverScenariosTest is
    SetupSUSDePYUSD,
    LeverScenariosTest
{
    function setUp() public override(SetupSUSDePYUSD, LeverScenariosTest) {
        SetupSUSDePYUSD.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSUSDePYUSD, Setup)
        returns (address)
    {
        return SetupSUSDePYUSD.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSUSDePYUSD, Setup) {
        SetupSUSDePYUSD.accrueYield(_amount);
    }
}
