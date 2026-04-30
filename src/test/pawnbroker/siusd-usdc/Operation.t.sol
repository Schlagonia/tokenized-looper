// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {OperationTest} from "../../base/Operation.t.sol";
import {Setup} from "../../base/Setup.sol";
import {SetupPawnBrokerSIUSD} from "./Setup.sol";

contract PawnBrokerSIUSDOperationTest is SetupPawnBrokerSIUSD, OperationTest {
    function setUp() public override(SetupPawnBrokerSIUSD, OperationTest) {
        SetupPawnBrokerSIUSD.setUp();
    }

    function setUpStrategy()
        public
        override(SetupPawnBrokerSIUSD, Setup)
        returns (address)
    {
        return SetupPawnBrokerSIUSD.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupPawnBrokerSIUSD, Setup) {
        SetupPawnBrokerSIUSD.accrueYield(_amount);
    }

    function test_setupStrategyOK() public override {
        OperationTest.test_setupStrategyOK();

        assertEq(address(looper.PAWN_BROKER()), address(pawnBroker));
        assertEq(address(looper.MORPHO()), MORPHO);
        assertEq(pawnBroker.BORROWER(), address(strategy));
        assertEq(pawnBroker.COLLATERAL_ASSET(), SIUSD);
        assertEq(pawnBroker.LLTV(), PAWN_BROKER_LLTV);
        assertEq(pawnBroker.rate(), PAWN_BROKER_RATE);
        assertEq(pawnBroker.pendingRate(), 0);
        assertEq(pawnBroker.pendingRateEffectiveTime(), 0);
        assertEq(pawnBroker.CALL_DURATION(), PAWN_BROKER_CALL_DURATION);
    }

    function test_marketDebtCallBlocksFreshDeposits() public {
        uint256 amount = 50_000e6;

        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.tend();

        uint256 debt = strategy.balanceOfDebt();

        vm.prank(management);
        pawnBroker.callDebt(debt / 4);

        assertEq(strategy.availableDepositLimit(user2), 0, "!deposit limit");

        airdrop(asset, user2, amount);
        vm.startPrank(user2);
        asset.approve(address(strategy), amount);
        vm.expectRevert();
        strategy.deposit(amount, user2);
        vm.stopPrank();
    }

    function test_marketShutdownBlocksFreshDeposits() public {
        uint256 amount = 50_000e6;

        vm.prank(management);
        pawnBroker.shutdownStrategy();

        assertEq(strategy.availableDepositLimit(user), 0, "!deposit limit");

        airdrop(asset, user, amount);
        vm.startPrank(user);
        asset.approve(address(strategy), amount);
        vm.expectRevert();
        strategy.deposit(amount, user);
        vm.stopPrank();
    }
}
