// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";
import {SetupSUSDSUSDT} from "./Setup.sol";

/// @notice sUSDS/USDT LeverScenarios tests - inherits all tests from LeverScenariosTest
contract SUSDSUSDTLeverScenariosTest is SetupSUSDSUSDT, LeverScenariosTest {
    function setUp() public override(SetupSUSDSUSDT, LeverScenariosTest) {
        SetupSUSDSUSDT.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSUSDSUSDT, Setup)
        returns (address)
    {
        return SetupSUSDSUSDT.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSUSDSUSDT, Setup) {
        SetupSUSDSUSDT.accrueYield(_amount);
    }

    function _defaultMaxAmountToSwap()
        internal
        pure
        override(SetupSUSDSUSDT, Setup)
        returns (uint256)
    {
        return SetupSUSDSUSDT._defaultMaxAmountToSwap();
    }
}
