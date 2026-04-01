// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {SetupSparkLST} from "./Setup.sol";
import {SparkStrategyAprOracle} from "../../../periphery/SparkStrategyAprOracle.sol";
import {IBaseLooper} from "../../../interfaces/IBaseLooper.sol";
import {IAaveLooper} from "../../../interfaces/IAaveLooper.sol";
import {IPoolDataProvider} from "../../../interfaces/aave/IPoolDataProvider.sol";
import {IReserveInterestRateStrategyLegacy} from "../../../interfaces/aave/IReserveInterestRateStrategyLegacy.sol";

interface IGlobalAprOracle {
    function getStrategyApr(
        address _strategy,
        int256 _debtChange
    ) external view returns (uint256);
}

contract SparkLSTAprOracleTest is SetupSparkLST {
    SparkStrategyAprOracle public oracle;
    address internal constant GLOBAL_APR_ORACLE =
        0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92;
    uint256 internal constant RAY_TO_WAD = 1e9;

    function setUp() public override {
        SetupSparkLST.setUp();
        oracle = new SparkStrategyAprOracle(management);
    }

    function setUpStrategy() public override returns (address) {
        return SetupSparkLST.setUpStrategy();
    }

    function accrueYield(uint256 _amount) public override {
        SetupSparkLST.accrueYield(_amount);
    }

    function _getReserveFactor(
        IPoolDataProvider dataProvider,
        address reserve
    ) internal view returns (uint256 reserveFactor) {
        (, , , , reserveFactor, , , , , ) = dataProvider
            .getReserveConfigurationData(reserve);
    }

    function _getReserveRateInputs(
        IPoolDataProvider dataProvider,
        address reserve
    )
        internal
        view
        returns (
            uint256 unbacked,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            uint256 averageStableBorrowRate
        )
    {
        (bool success, bytes memory data) = address(dataProvider).staticcall(
            abi.encodeWithSelector(
                IPoolDataProvider.getReserveData.selector,
                reserve
            )
        );
        require(success && data.length >= 32 * 12, "bad reserve data");

        assembly {
            unbacked := mload(add(data, 0x20))
            totalStableDebt := mload(add(data, 0x80))
            totalVariableDebt := mload(add(data, 0xa0))
            averageStableBorrowRate := mload(add(data, 0x120))
        }
    }

    function _getSparkLiquidityApr(
        IAaveLooper looper,
        address reserve
    ) internal view returns (uint256) {
        IPoolDataProvider dataProvider = looper.DATA_PROVIDER();
        (
            uint256 unbacked,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            uint256 averageStableBorrowRate
        ) = _getReserveRateInputs(dataProvider, reserve);
        (address aToken, , ) = dataProvider.getReserveTokensAddresses(reserve);

        IReserveInterestRateStrategyLegacy.CalculateInterestRatesParams
            memory params = IReserveInterestRateStrategyLegacy
                .CalculateInterestRatesParams({
                    unbacked: unbacked,
                    liquidityAdded: 0,
                    liquidityTaken: 0,
                    totalStableDebt: totalStableDebt,
                    totalVariableDebt: totalVariableDebt,
                    averageStableBorrowRate: averageStableBorrowRate,
                    reserveFactor: _getReserveFactor(dataProvider, reserve),
                    reserve: reserve,
                    aToken: aToken
                });

        address irStrategy = dataProvider.getInterestRateStrategyAddress(
            reserve
        );
        (uint256 liquidityRateRay, , ) = IReserveInterestRateStrategyLegacy(
            irStrategy
        ).calculateInterestRates(params);

        return liquidityRateRay / RAY_TO_WAD;
    }

    function test_aprAfterDebtChange_respectsDirection(
        uint256 _amount,
        uint16 _percentChange
    ) public {
        _amount = bound(_amount, 1e18, 10e18);
        _percentChange = uint16(bound(uint256(_percentChange), 300, 3000));

        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        uint256 delta = (_amount * _percentChange) / MAX_BPS;
        uint256 currentApr = oracle.aprAfterDebtChange(address(strategy), 0);
        uint256 aprAfterDebtIncrease = oracle.aprAfterDebtChange(
            address(strategy),
            int256(delta)
        );
        uint256 aprAfterDebtDecrease = oracle.aprAfterDebtChange(
            address(strategy),
            -int256(delta)
        );

        assertLe(
            aprAfterDebtIncrease,
            aprAfterDebtDecrease,
            "increase should not beat decrease"
        );

        assertLe(currentApr, 5e18, "current apr too high");
        assertLe(aprAfterDebtIncrease, 5e18, "increase apr too high");
        assertLe(aprAfterDebtDecrease, 5e18, "decrease apr too high");
    }

    function test_aprAfterDebtChange_returnsZeroWhenLeverageDisabled() public {
        vm.prank(management);
        strategy.setLeverageParams(0, 0, 1e18);

        uint256 apr = oracle.aprAfterDebtChange(
            address(strategy),
            int256(1e18)
        );
        assertEq(apr, 0, "!zero");
    }

    function test_aprAfterDebtChange_includesUnderlyingCollateralApr(
        uint256 _amount
    ) public {
        _amount = bound(_amount, 1e18, 10e18);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        vm.prank(management);
        strategy.setLeverageParams(1e18, 0.01e18, 2e18);

        IAaveLooper looper = IAaveLooper(address(strategy));
        address collateralToken = IBaseLooper(address(strategy))
            .collateralToken();
        uint256 aTokenApr = _getSparkLiquidityApr(looper, collateralToken);

        uint256 underlyingApr = IGlobalAprOracle(GLOBAL_APR_ORACLE)
            .getStrategyApr(collateralToken, 0);

        uint256 totalApr = oracle.aprAfterDebtChange(address(strategy), 0);
        assertEq(
            totalApr,
            aTokenApr + underlyingApr,
            "!underlying not included"
        );
    }
}
