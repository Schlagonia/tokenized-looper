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

    function test_setSUSDSReferral() public {
        assertEq(exchange.susdsReferral(), 1007, "!default referral");

        vm.prank(management);
        exchange.setSUSDSReferral(42);

        assertEq(exchange.susdsReferral(), 42, "!set referral");
    }

    function test_setSUSDSReferral_onlyManagement() public {
        vm.prank(user);
        vm.expectRevert("!governance");
        exchange.setSUSDSReferral(7);
    }

    function test_tendWithSUSDSReferral(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        vm.prank(management);
        exchange.setSUSDSReferral(7);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        assertGt(strategy.balanceOfCollateral(), 0, "!collateral");
    }

    function test_exchange_routes_areConfigured() public view {
        MetaExchange.RouteStep[] memory forward = exchange.getRoute(
            USDT,
            SUSDS
        );
        assertEq(forward.length, 3, "!forward length");
        assertEq(
            uint256(forward[0].venue),
            uint256(MetaExchange.Venue.UNISWAP_UNIVERSAL),
            "!forward venue 0"
        );
        assertEq(forward[0].tokenTo, USDC, "!forward token 0");
        assertEq(
            uint256(forward[1].venue),
            uint256(MetaExchange.Venue.LITE_PSM),
            "!forward venue 1"
        );
        assertEq(forward[1].tokenTo, USDS, "!forward token 1");
        assertEq(
            uint256(forward[2].venue),
            uint256(MetaExchange.Venue.SUSDS_DEPOSIT),
            "!forward venue 2"
        );
        assertEq(forward[2].tokenTo, SUSDS, "!forward token 2");

        MetaExchange.RouteStep[] memory reverse = exchange.getRoute(
            SUSDS,
            USDT
        );
        assertEq(reverse.length, 3, "!reverse length");
        assertEq(
            uint256(reverse[0].venue),
            uint256(MetaExchange.Venue.ERC4626_REDEEM),
            "!reverse venue 0"
        );
        assertEq(reverse[0].tokenTo, USDS, "!reverse token 0");
        assertEq(
            uint256(reverse[1].venue),
            uint256(MetaExchange.Venue.LITE_PSM),
            "!reverse venue 1"
        );
        assertEq(reverse[1].tokenTo, USDC, "!reverse token 1");
        assertEq(
            uint256(reverse[2].venue),
            uint256(MetaExchange.Venue.UNISWAP_UNIVERSAL),
            "!reverse venue 2"
        );
        assertEq(reverse[2].tokenTo, USDT, "!reverse token 2");
    }
}
