// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupAaveLST} from "./Setup.sol";

/// @notice Aave LST Operation tests - inherits all tests from OperationTest, uses Aave LST setup
contract AaveLSTOperationTest is SetupAaveLST, OperationTest {
    function setUp() public override(SetupAaveLST, OperationTest) {
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
