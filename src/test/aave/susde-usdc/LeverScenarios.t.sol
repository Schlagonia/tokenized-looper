// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {SetupAavesUSDeUSDC} from "./Setup.sol";

contract AavesUSDeUSDCLeverScenariosTest is
    SetupAavesUSDeUSDC,
    LeverScenariosTest
{
    function setUp() public override(SetupAavesUSDeUSDC, LeverScenariosTest) {
        SetupAavesUSDeUSDC.setUp();
    }

    function setUpStrategy()
        public
        override(SetupAavesUSDeUSDC, Setup)
        returns (address)
    {
        return SetupAavesUSDeUSDC.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupAavesUSDeUSDC, Setup) {
        SetupAavesUSDeUSDC.accrueYield(_amount);
    }

    function _simulateExitSwapData(
        uint256 _assetAmountNeeded
    )
        internal
        view
        override(SetupAavesUSDeUSDC, Setup)
        returns (bytes memory)
    {
        return SetupAavesUSDeUSDC._simulateExitSwapData(_assetAmountNeeded);
    }

    function _prepareExitSwapRoute()
        internal
        override(SetupAavesUSDeUSDC, Setup)
    {
        SetupAavesUSDeUSDC._prepareExitSwapRoute();
    }
}
