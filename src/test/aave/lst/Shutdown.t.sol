// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {ShutdownTest} from "../../base/Shutdown.t.sol";
import {SetupSparkLendLST} from "./Setup.sol";

/// @notice SparkLend LST Shutdown tests - inherits all tests from ShutdownTest, uses SparkLend LST setup
contract SparkLendLSTShutdownTest is SetupSparkLendLST, ShutdownTest {
    function setUp() public override(SetupSparkLendLST, ShutdownTest) {
        SetupSparkLendLST.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSparkLendLST, Setup)
        returns (address)
    {
        return SetupSparkLendLST.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSparkLendLST, Setup) {
        SetupSparkLendLST.accrueYield(_amount);
    }

    /// @notice SparkLend collateral indexes can move tiny dust while idle-mode repay executes.
    function test_idleMode_tendRepaysDebtAndLeavesExcessIdle(
        uint256 _amount
    ) public override {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        uint256 collateralBefore = strategy.balanceOfCollateral();
        uint256 debtBefore = strategy.balanceOfDebt();
        assertGt(debtBefore, 0, "!debt before");

        vm.prank(management);
        strategy.setLeverageParams(0, 0, 5e18);

        airdrop(asset, address(strategy), debtBefore * 2 + minFuzzAmount);
        uint256 assetBefore = strategy.balanceOfAsset();
        assertGt(assetBefore, debtBefore, "!idle before");

        skip(strategy.minTendInterval() + 1);

        vm.prank(keeper);
        strategy.tend();

        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertApproxEqAbs(
            strategy.balanceOfCollateral(),
            collateralBefore,
            1e6,
            "!collateral changed"
        );
        assertGt(strategy.balanceOfAsset(), 0, "!leftover idle");
        assertLt(
            strategy.balanceOfAsset(),
            assetBefore,
            "!repay did not spend"
        );
    }
}
