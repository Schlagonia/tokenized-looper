// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {SetupAaveSyrupUSDT} from "./Setup.sol";

/// @notice Aave syrupUSDT lever scenario tests
contract AaveSyrupUSDTLeverScenariosTest is
    SetupAaveSyrupUSDT,
    LeverScenariosTest
{
    function setUp() public override(SetupAaveSyrupUSDT, LeverScenariosTest) {
        SetupAaveSyrupUSDT.setUp();
    }

    function setUpStrategy()
        public
        override(SetupAaveSyrupUSDT, Setup)
        returns (address)
    {
        return SetupAaveSyrupUSDT.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupAaveSyrupUSDT, Setup) {
        SetupAaveSyrupUSDT.accrueYield(_amount);
    }
}
