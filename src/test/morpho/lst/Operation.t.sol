// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupLST} from "./Setup.sol";

/// @notice LST Operation tests - inherits all tests from OperationTest, uses LST setup
contract LSTOperationTest is SetupLST, OperationTest {
    function setUp() public override(SetupLST, OperationTest) {
        SetupLST.setUp();
    }

    function setUpStrategy()
        public
        override(SetupLST, Setup)
        returns (address)
    {
        return SetupLST.setUpStrategy();
    }

    function accrueYield(uint256 _amount) public override(SetupLST, Setup) {
        SetupLST.accrueYield(_amount);
    }

    function _maxUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure override returns (uint256) {
        // LST unwinds through AMMs and can leave larger residual wstETH dust.
        uint256 relativeDust = collateralBeforeUnwind / 100; // 1%
        return
            relativeDust > MIN_UNWIND_COLLATERAL_DUST
                ? relativeDust
                : MIN_UNWIND_COLLATERAL_DUST;
    }
}
