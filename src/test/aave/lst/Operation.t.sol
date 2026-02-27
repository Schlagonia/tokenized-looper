// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupAaveLST} from "./Setup.sol";

/// @notice Aave LST Operation tests - inherits all tests from OperationTest, uses Aave LST setup
contract AaveLSTOperationTest is SetupAaveLST, OperationTest {
    function setUp() public override(SetupAaveLST, OperationTest) {
        SetupAaveLST.setUp();
    }

    function setUpStrategy()
        public
        override(SetupAaveLST, Setup)
        returns (address)
    {
        return SetupAaveLST.setUpStrategy();
    }

    function accrueYield(uint256 _amount) public override(SetupAaveLST, Setup) {
        SetupAaveLST.accrueYield(_amount);
    }

    function _maxUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure override returns (uint256) {
        // LST unwind paths can leave larger residual collateral dust.
        uint256 relativeDust = collateralBeforeUnwind / 100; // 1%
        return
            relativeDust > MIN_UNWIND_COLLATERAL_DUST
                ? relativeDust
                : MIN_UNWIND_COLLATERAL_DUST;
    }

    function test_profitableReport(uint256 _amount) public override {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        accrueYield(_amount);

        vm.prank(keeper);
        strategy.report();

        skip(strategy.profitMaxUnlockTime());

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // LST path can realize mild unwind slippage in this setup.
        assertGe(
            asset.balanceOf(user),
            (_amount * 99) / 100,
            "!unexpected loss"
        );
    }

    function _createUnderLeveragedPositionAave(uint256 equity) internal {
        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.25e18, 5e18);

        mintAndDepositIntoStrategy(strategy, user, equity);
        vm.prank(keeper);
        strategy.tend();

        vm.prank(management);
        strategy.setLeverageParams(4e18, 0.5e18, 5e18);

        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 lowerBound = strategy.targetLeverageRatio() -
            strategy.leverageBuffer();
        assertLt(
            currentLeverage,
            lowerBound,
            "position should be under-leveraged"
        );
    }

    function test_tendTrigger_underLeveragedCanDeposit_noAutoTrigger()
        public
        override
    {
        uint256 equity = _baseTestAmount();
        _createUnderLeveragedPositionAave(equity);

        skip(strategy.minTendInterval() + 1);

        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 lowerBound = strategy.targetLeverageRatio() -
            strategy.leverageBuffer();
        assertLt(currentLeverage, lowerBound, "should be under-leveraged");

        uint256 maxDeposit = strategy.availableDepositLimit(address(strategy));
        uint256 minBorrow = strategy.minAmountToBorrow();
        assertGt(maxDeposit, minBorrow, "should have deposit capacity");

        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(
            trigger,
            "tendTrigger should return false when under-leveraged"
        );
    }

    function test_tendTrigger_underLeveragedCantDeposit() public override {
        uint256 equity = _baseTestAmount();
        _createUnderLeveragedPositionAave(equity);

        skip(strategy.minTendInterval() + 1);

        vm.prank(management);
        strategy.setDepositLimit(0);

        uint256 maxDeposit = strategy.availableDepositLimit(address(strategy));
        assertEq(maxDeposit, 0, "deposit capacity should be 0");

        uint256 currentLeverage = strategy.getCurrentLeverageRatio();
        uint256 lowerBound = strategy.targetLeverageRatio() -
            strategy.leverageBuffer();
        assertLt(
            currentLeverage,
            lowerBound,
            "should still be under-leveraged"
        );

        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(
            trigger,
            "tendTrigger should return false when under-leveraged but can't deposit"
        );
    }
}
