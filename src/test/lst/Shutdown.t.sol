// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../base/Setup.sol";
import {ShutdownTest} from "../base/Shutdown.t.sol";
import {SetupLST} from "./Setup.sol";

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
