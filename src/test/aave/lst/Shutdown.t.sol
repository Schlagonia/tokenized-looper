// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {ShutdownTest} from "../../base/Shutdown.t.sol";
import {SetupAaveLST} from "./Setup.sol";

/// @notice Aave LST Shutdown tests - inherits all tests from ShutdownTest, uses Aave LST setup
contract AaveLSTShutdownTest is SetupAaveLST, ShutdownTest {
    function setUp() public override(SetupAaveLST, ShutdownTest) {
        SetupAaveLST.setUp();
    }

    function setUpStrategy()
        public
        override(SetupAaveLST, Setup)
        returns (address)
    {
        return SetupAaveLST.setUpStrategy();
    }

    function accrueYield() public override(SetupAaveLST, Setup) {
        SetupAaveLST.accrueYield();
    }
}
