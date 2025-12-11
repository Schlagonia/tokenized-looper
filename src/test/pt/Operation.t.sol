// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../base/Setup.sol";
import {OperationTest} from "../base/Operation.t.sol";
import {SetupPT} from "./Setup.sol";

/// @notice PT Operation tests - inherits all tests from OperationTest, uses PT setup
contract PTOperationTest is SetupPT, OperationTest {
    function setUp() public override(SetupPT, OperationTest) {
        SetupPT.setUp();
    }

    function setUpStrategy() public override(SetupPT, Setup) returns (address) {
        return SetupPT.setUpStrategy();
    }

    function accrueYield() public override(SetupPT, Setup) {
        SetupPT.accrueYield();
    }
}
