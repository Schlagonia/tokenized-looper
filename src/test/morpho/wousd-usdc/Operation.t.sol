// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupWOUSDMorpho} from "./Setup.sol";

contract WOUSDMorphoOperationTest is SetupWOUSDMorpho, OperationTest {
    function setUp() public override(SetupWOUSDMorpho, OperationTest) {
        SetupWOUSDMorpho.setUp();
    }

    function setUpStrategy()
        public
        override(SetupWOUSDMorpho, Setup)
        returns (address)
    {
        return SetupWOUSDMorpho.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupWOUSDMorpho, Setup) {
        SetupWOUSDMorpho.accrueYield(_amount);
    }
}
