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
        assertEq(looper.collateralToken(), PT_USDG_28_MAY_2026);
        assertEq(looper.exchange(), address(exchange));
        assertEq(pawnBroker.BORROWER(), address(strategy));
        assertEq(pawnBroker.COLLATERAL_ASSET(), PT_USDG_28_MAY_2026);
        assertEq(pawnBroker.LLTV(), PAWN_BROKER_LLTV);
        assertEq(pawnBroker.rate(), PAWN_BROKER_RATE);
        assertEq(pawnBroker.pendingRate(), 0);
        assertEq(pawnBroker.pendingRateEffectiveTime(), 0);
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
