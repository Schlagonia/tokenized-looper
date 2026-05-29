// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {OperationTest} from "../../base/Operation.t.sol";
import {Setup} from "../../base/Setup.sol";
import {SetupPawnBrokerPTUSDG} from "./Setup.sol";

contract PawnBrokerPTUSDGOperationTest is SetupPawnBrokerPTUSDG, OperationTest {
    uint256 internal constant MIN_PT_UNWIND_DUST = 1e10;

    function setUp() public override(SetupPawnBrokerPTUSDG, OperationTest) {
        SetupPawnBrokerPTUSDG.setUp();
    }

    function setUpStrategy()
        public
        override(SetupPawnBrokerPTUSDG, Setup)
        returns (address)
    {
        return SetupPawnBrokerPTUSDG.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupPawnBrokerPTUSDG, Setup) {
        SetupPawnBrokerPTUSDG.accrueYield(_amount);
    }

    function _maxUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure override returns (uint256) {
        // PT unwinds can leave a few extra 18-decimal crumbs behind.
        uint256 relativeDust = (collateralBeforeUnwind * 5) / 10_000; // 5 bps
        return
            relativeDust > MIN_PT_UNWIND_DUST
                ? relativeDust
                : MIN_PT_UNWIND_DUST;
    }

    function test_setupStrategyOK() public override {
        OperationTest.test_setupStrategyOK();

        assertEq(address(looper.PAWN_BROKER()), address(pawnBroker));
        assertEq(address(looper.MORPHO()), MORPHO);
        assertEq(looper.collateralToken(), PT_USDG_24_SEP_2026);
        assertEq(looper.exchange(), address(exchange));
        assertEq(pawnBroker.BORROWER(), address(strategy));
        assertEq(pawnBroker.COLLATERAL_ASSET(), PT_USDG_24_SEP_2026);
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
        assertEq(oracle.price(), PT_ORACLE_PRICE);
    }

    function test_marketDebtCallBlocksFreshDeposits() public {
        uint256 amount = 5_000e6;

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
        uint256 amount = 5_000e6;

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

        uint256 sharesToRedeem = strategy.maxRedeem(user) / 4;
        assertGt(sharesToRedeem, 0, "!shares");

        uint256 userBalanceBefore = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(sharesToRedeem, user, user);

        assertGt(asset.balanceOf(user), userBalanceBefore, "!withdraw");
        assertTrue(pawnBroker.isSolvent(), "!solvent");
    }

    function test_marketDebtCallMaxRedeemUsesWithdrawableEquity() public {
        uint256 amount = 5_000e6;

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
        uint256 amount = 5_000e6;

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
