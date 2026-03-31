// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {ShutdownTest} from "../../base/Shutdown.t.sol";
import {SetupAaveSyrupUSDT} from "./Setup.sol";

/// @notice Aave syrupUSDT shutdown tests
contract AaveSyrupUSDTShutdownTest is SetupAaveSyrupUSDT, ShutdownTest {
    function setUp() public override(SetupAaveSyrupUSDT, ShutdownTest) {
        SetupAaveSyrupUSDT.setUp();
    }

    function setUpStrategy()
        public
        override(SetupAaveSyrupUSDT, Setup)
        returns (address)
    {
        return SetupAaveSyrupUSDT.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupAaveSyrupUSDT, Setup) {
        SetupAaveSyrupUSDT.accrueYield(_amount);
    }
}
