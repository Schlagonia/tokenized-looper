// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "./utils/Setup.sol";
import {OperationTest} from "./Operation.t.sol";
import {SetupLST} from "./utils/SetupLST.sol";

/// @notice LST Operation tests - inherits all tests from OperationTest, uses LST setup
contract LSTOperationTest is SetupLST, OperationTest {
    function setUp() public override(SetupLST, OperationTest) {
        SetupLST.setUp();
    }

    function setUpStrategy()
        public
        override(SetupLST, Setup)
        returns (address)
    {
        return SetupLST.setUpStrategy();
    }

    function accrueYield() public override(SetupLST, Setup) {
        SetupLST.accrueYield();
    }
}
