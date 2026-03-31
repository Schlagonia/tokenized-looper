// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {SetupAaveLST} from "./Setup.sol";
import {AaveStrategyAprOracle} from "../../../periphery/AaveStrategyAprOracle.sol";
import {IBaseLooper} from "../../../interfaces/IBaseLooper.sol";
import {IAaveLooper} from "../../../interfaces/IAaveLooper.sol";
import {IPool} from "../../../interfaces/aave/IPool.sol";
import {IPoolDataProvider} from "../../../interfaces/aave/IPoolDataProvider.sol";
import {IReserveInterestRateStrategy} from "../../../interfaces/aave/IReserveInterestRateStrategy.sol";

interface IGlobalAprOracle {
    function getStrategyApr(
        address _strategy,
        int256 _debtChange
    ) external view returns (uint256);
}

contract AaveLSTAprOracleTest is SetupAaveLST {
    AaveStrategyAprOracle public oracle;
    address internal constant GLOBAL_APR_ORACLE =
        0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92;
    uint256 internal constant RAY_TO_WAD = 1e9;

    function setUp() public override {
        SetupAaveLST.setUp();
        oracle = new AaveStrategyAprOracle(management);
    }

    function setUpStrategy() public override returns (address) {
        return SetupAaveLST.setUpStrategy();
    }

    function accrueYield(uint256 _amount) public override {
        SetupAaveLST.accrueYield(_amount);
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

        // Strategy APRs should stay in sane annualized bounds.
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
        IPoolDataProvider dataProvider = looper.DATA_PROVIDER();

        (, , , , uint256 reserveFactor, , , , , ) = dataProvider
            .getReserveConfigurationData(collateralToken);
        (uint256 unbacked, , , , , , , , , , , ) = dataProvider.getReserveData(
            collateralToken
        );

        uint256 totalDebt = dataProvider.getTotalDebt(collateralToken);
        uint256 virtualUnderlyingBalance = IPool(looper.POOL())
            .getVirtualUnderlyingBalance(collateralToken);
        bool usingVirtualBalance = virtualUnderlyingBalance > 0;

        IReserveInterestRateStrategy.CalculateInterestRatesParams
            memory params = IReserveInterestRateStrategy
                .CalculateInterestRatesParams({
                    unbacked: unbacked,
                    liquidityAdded: 0,
                    liquidityTaken: 0,
                    totalDebt: totalDebt,
                    reserveFactor: reserveFactor,
                    reserve: collateralToken,
                    usingVirtualBalance: usingVirtualBalance,
                    virtualUnderlyingBalance: virtualUnderlyingBalance
                });

        address irStrategy = dataProvider.getInterestRateStrategyAddress(
            collateralToken
        );
        (uint256 liquidityRateRay, ) = IReserveInterestRateStrategy(irStrategy)
            .calculateInterestRates(params);
        uint256 aTokenApr = liquidityRateRay / RAY_TO_WAD;

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
