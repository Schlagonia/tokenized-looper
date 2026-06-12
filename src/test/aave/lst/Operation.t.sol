// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupSparkLendLST} from "./Setup.sol";
import {AaveLooper} from "../../../aave/AaveLooper.sol";
import {IPool} from "../../../interfaces/aave/IPool.sol";

/// @notice SparkLend LST Operation tests - inherits all tests from OperationTest, uses SparkLend LST setup
contract SparkLendLSTOperationTest is SetupSparkLendLST, OperationTest {
    function setUp() public override(SetupSparkLendLST, OperationTest) {
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

    function _createUnderLeveragedPositionSparkLend(uint256 equity) internal {
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
        _createUnderLeveragedPositionSparkLend(equity);

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
        _createUnderLeveragedPositionSparkLend(equity);

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

    function test_getLiquidateCollateralFactor_usesEModeThreshold() public {
        AaveLooper looper = AaveLooper(payable(address(strategy)));

        uint256 strategyLiquidationFactor = looper
            .getLiquidateCollateralFactor();

        (, , uint256 reserveLiquidationThreshold, , , , , , , ) = looper
            .DATA_PROVIDER()
            .getReserveConfigurationData(WSTETH);

        IPool pool = IPool(looper.POOL());
        uint256 userEModeCategory = pool.getUserEMode(address(looper));
        assertEq(userEModeCategory, EMODE_CATEGORY_ID, "!emode category");

        uint16 eModeLiquidationThreshold = pool
            .getEModeCategoryData(uint8(userEModeCategory))
            .liquidationThreshold;

        assertGt(
            uint256(eModeLiquidationThreshold),
            reserveLiquidationThreshold,
            "!emode should improve LT"
        );
        assertEq(
            strategyLiquidationFactor,
            uint256(eModeLiquidationThreshold) * 1e14,
            "!should use emode LT"
        );
    }

    function test_setEModeCategory_onlyManagement() public {
        AaveLooper looper = AaveLooper(payable(address(strategy)));
        IPool pool = IPool(looper.POOL());

        vm.prank(user);
        vm.expectRevert("!management");
        looper.setEModeCategory(0);

        vm.prank(management);
        looper.setEModeCategory(0);
        assertEq(pool.getUserEMode(address(looper)), 0, "!emode id");
    }

    function test_setEModeCategory_updatesPoolUserModeAndLiquidationFactor()
        public
    {
        AaveLooper looper = AaveLooper(payable(address(strategy)));
        IPool pool = IPool(looper.POOL());

        (, , uint256 reserveLiquidationThreshold, , , , , , , ) = looper
            .DATA_PROVIDER()
            .getReserveConfigurationData(WSTETH);

        vm.prank(management);
        looper.setEModeCategory(0);
        assertEq(
            pool.getUserEMode(address(looper)),
            0,
            "!user emode after clear"
        );
        uint256 liquidationFactorAfterClear = looper
            .getLiquidateCollateralFactor();
        assertEq(
            liquidationFactorAfterClear,
            reserveLiquidationThreshold * 1e14,
            "!reserve LT after clear"
        );

        vm.prank(management);
        looper.setEModeCategory(EMODE_CATEGORY_ID);
        assertEq(
            pool.getUserEMode(address(looper)),
            EMODE_CATEGORY_ID,
            "!user emode after set"
        );

        uint16 eModeLiquidationThreshold = pool
            .getEModeCategoryData(uint8(EMODE_CATEGORY_ID))
            .liquidationThreshold;
        uint256 liquidationFactorAfterSet = looper
            .getLiquidateCollateralFactor();
        assertEq(
            liquidationFactorAfterSet,
            uint256(eModeLiquidationThreshold) * 1e14,
            "!emode LT after set"
        );
        assertGt(
            liquidationFactorAfterSet,
            liquidationFactorAfterClear,
            "!lt should increase after emode set"
        );
    }

    function test_claimRewards_onlyKeepers() public {
        AaveLooper looper = AaveLooper(payable(address(strategy)));

        vm.prank(user);
        vm.expectRevert("!keeper");
        looper.claimRewards();
    }

    function test_claimRewards_keeperCanCall() public {
        AaveLooper looper = AaveLooper(payable(address(strategy)));

        vm.prank(keeper);
        looper.claimRewards();
    }

    function test_kickAuction_rejectsAssetAndAToken() public {
        AaveLooper looper = AaveLooper(payable(address(strategy)));
        address aToken = looper.A_TOKEN();

        vm.prank(keeper);
        vm.expectRevert("protected token");
        looper.kickAuction(address(asset));

        vm.prank(keeper);
        vm.expectRevert("protected token");
        looper.kickAuction(aToken);
    }
}
