// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {ShutdownTest} from "../../base/Shutdown.t.sol";

/// @notice Infinifi Shutdown tests - uses base Setup which deploys InfinifiMorphoLooper
contract InfinifiShutdownTest is ShutdownTest {
    function setUp() public override {
        super.setUp();
    }
}
