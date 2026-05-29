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
        (uint256 pendingRate, uint256 pendingRateEffectiveTime) = pawnBroker
            .pendingRateUpdate();
        assertEq(pendingRate, 0);
        assertEq(pendingRateEffectiveTime, 0);
        assertEq(pawnBroker.liquidationBonusBps(), 100);
        (
            uint256 pendingLiquidationBonus,
            uint256 pendingLiquidationBonusEffectiveTime
        ) = pawnBroker.pendingLiquidationBonusUpdate();
        assertEq(pendingLiquidationBonus, 0);
        assertEq(pendingLiquidationBonusEffectiveTime, 0);
        assertFalse(pawnBroker.paused());
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

    function test_marketDebtCallAllowsPartialWithdraws() public {
        uint256 amount = 50_000e6;

        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.tend();

        uint256 idle = strategy.balanceOfAsset();
        uint256 debt = strategy.balanceOfDebt();
        assertGt(debt, 0, "!debt");

        vm.prank(management);
        pawnBroker.callDebt(debt / 4);

        assertGt(pawnBroker.calledDebt(), 0, "!called debt");

        uint256 limit = strategy.availableWithdrawLimit(user);
        assertEq(limit, _expectedAvailableWithdrawLimit(), "!withdraw limit");
        assertGt(limit, idle, "!equity unavailable");

        uint256 maxWithdraw = strategy.maxWithdraw(user);
        assertGt(maxWithdraw, idle, "!max withdraw");

        uint256 userBalanceBefore = asset.balanceOf(user);
        vm.prank(user);
        strategy.withdraw(maxWithdraw / 4, user, user);

        assertGt(asset.balanceOf(user), userBalanceBefore, "!withdraw");
        assertTrue(pawnBroker.isSolvent(), "!solvent");
    }

    function test_marketDebtCallMaxRedeemUsesWithdrawableEquity() public {
        uint256 amount = 50_000e6;

        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.tend();

        uint256 debt = strategy.balanceOfDebt();
        assertGt(debt, 0, "!debt");

        vm.prank(management);
        pawnBroker.callDebt(debt / 4);

        uint256 limit = strategy.availableWithdrawLimit(user);
        uint256 holderBalance = strategy.balanceOf(user);
        uint256 maxRedeem = strategy.maxRedeem(user);
        uint256 maxRedeemAssets = strategy.previewRedeem(maxRedeem);

        assertGt(limit, strategy.balanceOfAsset(), "!equity unavailable");
        assertGt(maxRedeem, 0, "!max redeem");
        assertLe(maxRedeem, holderBalance, "!holder balance");
        assertLe(maxRedeemAssets, limit, "!limit");

        uint256 userBalanceBefore = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(maxRedeem, user, user);

        assertGt(asset.balanceOf(user), userBalanceBefore, "!redeem");
        assertTrue(pawnBroker.isSolvent(), "!solvent");
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
