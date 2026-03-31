// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {ShutdownTest} from "../../base/Shutdown.t.sol";
import {SetupSUSDSUSDT} from "./Setup.sol";

/// @notice sUSDS/USDT Shutdown tests - inherits all tests from ShutdownTest
contract SUSDSUSDTShutdownTest is SetupSUSDSUSDT, ShutdownTest {
    function setUp() public override(SetupSUSDSUSDT, ShutdownTest) {
        SetupSUSDSUSDT.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSUSDSUSDT, Setup)
        returns (address)
    {
        return SetupSUSDSUSDT.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSUSDSUSDT, Setup) {
        SetupSUSDSUSDT.accrueYield(_amount);
    }
}
