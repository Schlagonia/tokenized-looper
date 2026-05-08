// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {SetupEulerSyrupRLUSD} from "./Setup.sol";

/// @notice syrupUSDC/RLUSD Euler lever scenario tests.
contract EulerSyrupRLUSDLeverScenariosTest is
    SetupEulerSyrupRLUSD,
    LeverScenariosTest
{
    function setUp() public override(SetupEulerSyrupRLUSD, LeverScenariosTest) {
        SetupEulerSyrupRLUSD.setUp();
    }

    function setUpStrategy()
        public
        override(SetupEulerSyrupRLUSD, Setup)
        returns (address)
    {
        return SetupEulerSyrupRLUSD.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupEulerSyrupRLUSD, Setup) {
        SetupEulerSyrupRLUSD.accrueYield(_amount);
    }
}
