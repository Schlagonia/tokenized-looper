// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {OperationTest} from "../base/Operation.t.sol";

/// @notice Infinifi Operation tests - uses base Setup which deploys InfinifiMorphoLooper
contract InfinifiOperationTest is OperationTest {
    function setUp() public override {
        super.setUp();
    }
}
