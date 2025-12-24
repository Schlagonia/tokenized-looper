// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupPTArb} from "./Setup.sol";

contract PTArbOperationTest is SetupPTArb, OperationTest {
    function setUp() public override(SetupPTArb, OperationTest) {
        SetupPTArb.setUp();
    }

    function setUpStrategy()
        public
        override(SetupPTArb, Setup)
        returns (address)
    {
        return SetupPTArb.setUpStrategy();
    }

    function accrueYield() public override(SetupPTArb, Setup) {
        SetupPTArb.accrueYield();
    }

    /// @notice Override to check 5x leverage instead of 3x
    function test_setupStrategyOK() public override {
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        assertTrue(
            strategy.collateralToken() != address(0),
            "!collateralToken"
        );

        // PT uses 5x leverage instead of 3x
        assertEq(strategy.targetLeverageRatio(), 5e18, "!targetLeverageRatio");
        assertEq(strategy.leverageBuffer(), 0.25e18, "!leverageBuffer");
    }
}
