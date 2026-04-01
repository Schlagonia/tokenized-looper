// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {ShutdownTest} from "../../base/Shutdown.t.sol";
import {SetupSparkLST} from "./Setup.sol";

contract SparkLSTShutdownTest is SetupSparkLST, ShutdownTest {
    function setUp() public override(SetupSparkLST, ShutdownTest) {
        SetupSparkLST.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSparkLST, Setup)
        returns (address)
    {
        return SetupSparkLST.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSparkLST, Setup) {
        SetupSparkLST.accrueYield(_amount);
    }
}
