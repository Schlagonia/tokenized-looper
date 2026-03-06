// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {SetupSyrupUsdcArbMorpho} from "./Setup.sol";

contract SyrupUsdcArbMorphoLeverScenariosTest is
    SetupSyrupUsdcArbMorpho,
    LeverScenariosTest
{
    function setUp()
        public
        override(SetupSyrupUsdcArbMorpho, LeverScenariosTest)
    {
        SetupSyrupUsdcArbMorpho.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSyrupUsdcArbMorpho, Setup)
        returns (address)
    {
        return SetupSyrupUsdcArbMorpho.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSyrupUsdcArbMorpho, Setup) {
        SetupSyrupUsdcArbMorpho.accrueYield(_amount);
    }
}
