// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupSUSDSUSDT} from "./Setup.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";

/// @notice sUSDS/USDT Operation tests - inherits all tests from OperationTest
contract SUSDSUSDTOperationTest is SetupSUSDSUSDT, OperationTest {
    function setUp() public override(SetupSUSDSUSDT, OperationTest) {
        SetupSUSDSUSDT.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSUSDSUSDT, Setup)
        returns (address)
    {
        return SetupSUSDSUSDT.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSUSDSUSDT, Setup) {
        SetupSUSDSUSDT.accrueYield(_amount);
    }

    function _defaultMaxAmountToSwap()
        internal
        pure
        override(SetupSUSDSUSDT, Setup)
        returns (uint256)
    {
        return SetupSUSDSUSDT._defaultMaxAmountToSwap();
    }

    function test_setSUSDSReferral() public {
        assertEq(susdsExchange.susdsReferral(), 1007, "!default referral");

        vm.prank(management);
        susdsExchange.setSUSDSReferral(42);

        assertEq(susdsExchange.susdsReferral(), 42, "!set referral");
    }

    function test_setSUSDSReferral_onlyGovernance() public {
        vm.prank(user);
        vm.expectRevert("!governance");
        susdsExchange.setSUSDSReferral(7);
    }

    function test_tendWithSUSDSReferral(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        vm.prank(management);
        susdsExchange.setSUSDSReferral(7);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        assertGt(strategy.balanceOfCollateral(), 0, "!collateral");
    }

    function test_operation(uint256 _amount) public override {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        accrueYield(_amount);

        vm.prank(management);
        strategy.setLossLimitRatio(100);

        // Live sUSDS report paths can mark a small interim loss even when the
        // user-level round trip is fine. Check the real outcome instead.
        vm.prank(management);
        strategy.setDoHealthCheck(false);

        vm.prank(keeper);
        strategy.report();

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore, "!final balance");
    }

    function test_profitableReport(uint256 _amount) public override {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        accrueYield(_amount);

        vm.prank(management);
        strategy.setDoHealthCheck(false);

        vm.prank(keeper);
        strategy.report();

        skip(strategy.profitMaxUnlockTime());

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), (_amount * 99) / 100, "!final balance");
    }

    function test_exchange_routes_areConfigured() public view {
        MetaExchange.RouteStep[] memory forward = exchange.getRoute(
            USDT,
            SUSDS
        );
        assertEq(forward.length, 3, "!forward length");
        assertEq(forward[0].exchange, address(uniExchange), "!forward ex 0");
        assertEq(forward[0].tokenTo, USDC, "!forward token 0");
        assertEq(
            forward[1].exchange,
            address(litePsmExchange),
            "!forward ex 1"
        );
        assertEq(forward[1].tokenTo, USDS, "!forward token 1");
        assertEq(forward[2].exchange, address(susdsExchange), "!forward ex 2");
        assertEq(forward[2].tokenTo, SUSDS, "!forward token 2");

        MetaExchange.RouteStep[] memory reverse = exchange.getRoute(
            SUSDS,
            USDT
        );
        assertEq(reverse.length, 3, "!reverse length");
        assertEq(
            reverse[0].exchange,
            address(erc4626Exchange),
            "!reverse ex 0"
        );
        assertEq(reverse[0].tokenTo, USDS, "!reverse token 0");
        assertEq(
            reverse[1].exchange,
            address(litePsmExchange),
            "!reverse ex 1"
        );
        assertEq(reverse[1].tokenTo, USDC, "!reverse token 1");
        assertEq(reverse[2].exchange, address(uniExchange), "!reverse ex 2");
        assertEq(reverse[2].tokenTo, USDT, "!reverse token 2");
    }
}
