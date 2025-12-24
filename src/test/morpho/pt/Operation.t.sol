// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupPT} from "./Setup.sol";

/// @notice PT Operation tests - inherits all tests from OperationTest, uses PT setup
contract PTOperationTest is SetupPT, OperationTest {
    function setUp() public override(SetupPT, OperationTest) {
        SetupPT.setUp();
    }

    function setUpStrategy() public override(SetupPT, Setup) returns (address) {
        return SetupPT.setUpStrategy();
    }

    function accrueYield() public override(SetupPT, Setup) {
        SetupPT.accrueYield();
        //airdrop(asset, address(strategy), minFuzzAmount / 10);
    }

    /// @notice Override to check PT-specific leverage params (5x instead of 3x)
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
