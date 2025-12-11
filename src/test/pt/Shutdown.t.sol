// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../base/Setup.sol";
import {ShutdownTest} from "../base/Shutdown.t.sol";
import {SetupPT} from "./Setup.sol";

/// @notice PT Shutdown tests - inherits all tests from ShutdownTest, uses PT setup
contract PTShutdownTest is SetupPT, ShutdownTest {
    function setUp() public override(SetupPT, ShutdownTest) {
        SetupPT.setUp();
    }

    function setUpStrategy() public override(SetupPT, Setup) returns (address) {
        return SetupPT.setUpStrategy();
    }

    function accrueYield() public override(SetupPT, Setup) {
        SetupPT.accrueYield();
    }
}
