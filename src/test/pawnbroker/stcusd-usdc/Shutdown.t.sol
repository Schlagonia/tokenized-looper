// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {ShutdownTest} from "../../base/Shutdown.t.sol";
import {Setup} from "../../base/Setup.sol";
import {SetupPawnBrokerSTCUSD} from "./Setup.sol";

contract PawnBrokerSTCUSDShutdownTest is SetupPawnBrokerSTCUSD, ShutdownTest {
    function setUp() public override(SetupPawnBrokerSTCUSD, ShutdownTest) {
        SetupPawnBrokerSTCUSD.setUp();
    }

    function setUpStrategy()
        public
        override(SetupPawnBrokerSTCUSD, Setup)
        returns (address)
    {
        return SetupPawnBrokerSTCUSD.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupPawnBrokerSTCUSD, Setup) {
        SetupPawnBrokerSTCUSD.accrueYield(_amount);
    }
}
