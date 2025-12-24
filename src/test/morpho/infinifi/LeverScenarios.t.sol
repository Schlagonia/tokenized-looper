// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {LeverScenariosTest} from "../../base/LeverScenarios.t.sol";

/// @notice Infinifi LeverScenarios tests - uses base Setup which deploys InfinifiMorphoLooper
contract InfinifiLeverScenariosTest is LeverScenariosTest {
    function setUp() public override {
        super.setUp();
    }
}
