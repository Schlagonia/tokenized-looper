// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../base/Setup.sol";
import {ShutdownTest} from "../base/Shutdown.t.sol";
import {SetupPTArb} from "./Setup.sol";

contract PTArbShutdownTest is SetupPTArb, ShutdownTest {
    function setUp() public override(SetupPTArb, ShutdownTest) {
        SetupPTArb.setUp();
    }

    function setUpStrategy()
        public
        override(SetupPTArb, Setup)
        returns (address)
    {
        return SetupPTArb.setUpStrategy();
    }

    function accrueYield(uint256 _amount) public override(SetupPTArb, Setup) {
        SetupPTArb.accrueYield(_amount);
    }
}
