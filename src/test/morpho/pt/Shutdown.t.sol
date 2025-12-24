// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {ShutdownTest} from "../../base/Shutdown.t.sol";
import {SetupPT} from "./Setup.sol";

/// @notice PT Shutdown tests - inherits all tests from ShutdownTest, uses PT setup
contract PTShutdownTest is SetupPT, ShutdownTest {
    function setUp() public override(SetupPT, ShutdownTest) {
        SetupPT.setUp();
    }

    function setUpStrategy() public override(SetupPT, Setup) returns (address) {
        return SetupPT.setUpStrategy();
    }

    function accrueYield() public override(SetupPT, Setup) {
        SetupPT.accrueYield();
    }

    /// @notice Override with higher slippage tolerance for PT swaps (~1%)
    function test_shutdownCanWithdraw(uint256 _amount) public override {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        assertGt(strategy.totalAssets(), 0, "!totalAssets");

        accrueYield();

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertGt(strategy.totalAssets(), 0, "!totalAssets");

        uint256 balanceBefore = asset.balanceOf(user);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // PT swaps have higher slippage due to 5x leverage compounding
        assertApproxEqRel(
            asset.balanceOf(user),
            balanceBefore + _amount,
            0.02e18 // 2% tolerance
        );
    }

    /// @notice Override with higher slippage tolerance for PT swaps
    function test_emergencyWithdraw_maxUint(uint256 _amount) public override {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        accrueYield();

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

        uint256 balanceBefore = asset.balanceOf(user);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // PT swaps have higher slippage due to 5x leverage compounding
        assertApproxEqRel(
            asset.balanceOf(user),
            balanceBefore + _amount,
            0.02e18 // 2% tolerance
        );
    }
}
