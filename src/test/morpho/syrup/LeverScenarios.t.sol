// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {SetupSyrupMorpho} from "./Setup.sol";

/// @notice syrup/USDC Morpho lever scenario tests
contract SyrupMorphoLeverScenariosTest is SetupSyrupMorpho, LeverScenariosTest {
    function setUp() public override(SetupSyrupMorpho, LeverScenariosTest) {
        SetupSyrupMorpho.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSyrupMorpho, Setup)
        returns (address)
    {
        return SetupSyrupMorpho.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSyrupMorpho, Setup) {
        SetupSyrupMorpho.accrueYield(_amount);
    }
}
