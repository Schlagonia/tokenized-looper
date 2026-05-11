// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {ShutdownTest} from "../../base/Shutdown.t.sol";
import {SetupAaveLST} from "./Setup.sol";

/// @notice Aave LST Shutdown tests - inherits all tests from ShutdownTest, uses Aave LST setup
contract AaveLSTShutdownTest is SetupAaveLST, ShutdownTest {
    function _assertIdleCollateralUnchanged(
        uint256 actual,
        uint256 expected,
        string memory message
    ) internal override {
        // Aave aToken balances can drift by a few wei of yield while idle-mode tests skip time.
        assertApproxEqRel(actual, expected, 1e10, message);
    }

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

    function accrueYield(uint256 _amount) public override(SetupAaveLST, Setup) {
        SetupAaveLST.accrueYield(_amount);
    }
}
