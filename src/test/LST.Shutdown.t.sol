// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "./utils/Setup.sol";
import {ShutdownTest} from "./Shutdown.t.sol";
import {SetupLST} from "./utils/SetupLST.sol";

/// @notice LST Shutdown tests - inherits all tests from ShutdownTest, uses LST setup
contract LSTShutdownTest is SetupLST, ShutdownTest {
    function setUp() public override(SetupLST, ShutdownTest) {
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
