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

    function accrueYield(uint256 _amount) public override(SetupPTArb, Setup) {
        SetupPTArb.accrueYield(_amount);
    }

    function _maxUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure override returns (uint256) {
        // PT-Arb unwinds can leave more residual collateral due thinner liquidity.
        uint256 relativeDust = collateralBeforeUnwind / 100; // 1%
        return
            relativeDust > MIN_UNWIND_COLLATERAL_DUST
                ? relativeDust
                : MIN_UNWIND_COLLATERAL_DUST;
    }

    /// @notice PT now uses base Morpho looper defaults.
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

        assertEq(strategy.targetLeverageRatio(), 3e18, "!targetLeverageRatio");
        assertEq(strategy.leverageBuffer(), 0.25e18, "!leverageBuffer");
    }

    function test_operation(uint256 _amount) public override {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        accrueYield(_amount);

        // PT-Arb route can realize larger temporary mark-to-market losses on report.
        vm.startPrank(management);
        strategy.setLossLimitRatio(2_000);
        strategy.setDoHealthCheck(false);
        vm.stopPrank();

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

        vm.startPrank(management);
        strategy.setLossLimitRatio(2_000);
        strategy.setDoHealthCheck(false);
        vm.stopPrank();

        vm.prank(keeper);
        strategy.report();

        skip(strategy.profitMaxUnlockTime());

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGt(asset.balanceOf(user), _amount, "!profit not realized");
    }
}
