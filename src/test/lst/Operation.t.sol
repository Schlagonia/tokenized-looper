// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../base/Setup.sol";
import {OperationTest} from "../base/Operation.t.sol";
import {SetupLST} from "./Setup.sol";

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

    function accrueYield(uint256 _amount) public override(SetupLST, Setup) {
        SetupLST.accrueYield(_amount);
    }
}
