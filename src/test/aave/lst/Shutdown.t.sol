// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {ShutdownTest} from "../../base/Shutdown.t.sol";
import {SetupSparkLendLST} from "./Setup.sol";

/// @notice SparkLend LST Shutdown tests - inherits all tests from ShutdownTest, uses SparkLend LST setup
contract SparkLendLSTShutdownTest is SetupSparkLendLST, ShutdownTest {
    function setUp() public override(SetupSparkLendLST, ShutdownTest) {
        SetupSparkLendLST.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSparkLendLST, Setup)
        returns (address)
    {
        return SetupSparkLendLST.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSparkLendLST, Setup) {
        SetupSparkLendLST.accrueYield(_amount);
    }
}
