// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {ShutdownTest} from "../../base/Shutdown.t.sol";
import {Setup} from "../../base/Setup.sol";
import {SetupPawnBrokerPTUSDG} from "./Setup.sol";

contract PawnBrokerPTUSDGShutdownTest is SetupPawnBrokerPTUSDG, ShutdownTest {
    function setUp() public override(SetupPawnBrokerPTUSDG, ShutdownTest) {
        SetupPawnBrokerPTUSDG.setUp();
    }

    function setUpStrategy()
        public
        override(SetupPawnBrokerPTUSDG, Setup)
        returns (address)
    {
        return SetupPawnBrokerPTUSDG.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupPawnBrokerPTUSDG, Setup) {
        SetupPawnBrokerPTUSDG.accrueYield(_amount);
    }
}
