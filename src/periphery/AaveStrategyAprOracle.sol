// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IBaseLooper} from "../interfaces/IBaseLooper.sol";
import {IAaveLooper} from "../interfaces/IAaveLooper.sol";
import {IPool} from "../interfaces/aave/IPool.sol";
import {IPoolDataProvider} from "../interfaces/aave/IPoolDataProvider.sol";
import {IReserveInterestRateStrategy} from "../interfaces/aave/IReserveInterestRateStrategy.sol";

interface IGlobalAprOracle {
    function getStrategyApr(
        address _strategy,
        int256 _debtChange
    ) external view returns (uint256);
}

contract AaveStrategyAprOracle is AprOracleBase {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY_TO_WAD = 1e9;

    address public constant GLOBAL_APR_ORACLE =
        0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92;

    struct BorrowSnapshot {
        uint256 unbacked;
        uint256 totalDebt;
        uint256 reserveFactor;
        bool usingVirtualBalance;
        uint256 virtualUnderlyingBalance;
        address aTokenAddress;
        address interestRateStrategyAddress;
    }

    constructor(
        address _governance
    ) AprOracleBase("Aave Looper Strategy Apr Oracle", _governance) {}

    /**
     * @notice Will return the expected Apr of a strategy post a debt change.
     * @param _strategy The strategy to get the apr for.
     * @param _delta The equity change in asset units.
     * @return The expected apr represented as 1e18.
     */
    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view override returns (uint256) {
        uint256 leverage = IBaseLooper(_strategy).targetLeverageRatio();
        if (leverage == 0) return 0;

        uint256 baseAssets = IBaseLooper(_strategy).estimatedTotalAssets();
        if (baseAssets == 0 && _delta <= 0) return 0;

        int256 equityAfterInt = int256(baseAssets) + _delta;
        if (equityAfterInt <= 0) equityAfterInt = 0;
        uint256 equityAfter = uint256(equityAfterInt);

        uint256 collateralValue = (equityAfter * leverage) / WAD;
        int256 debtDelta = (_delta * int256(leverage - WAD)) / int256(WAD);

        uint256 borrowApr = _getBorrowApr(_strategy, debtDelta);
        uint256 collateralApr = _getCollateralApr(
            _strategy,
            _delta,
            leverage,
            collateralValue
        );

        return _netApr(leverage, collateralApr, borrowApr);
    }

    function _getBorrowApr(
        address _strategy,
        int256 debtDelta
    ) internal view returns (uint256) {
        IAaveLooper looper = IAaveLooper(_strategy);

        (, uint256 variableBorrowApr) = _calculateRates(
            looper.DATA_PROVIDER(),
            looper.POOL(),
            IBaseLooper(_strategy).asset(),
            debtDelta,
            -debtDelta
        );

        return variableBorrowApr;
    }

    function _getCollateralApr(
        address _strategy,
        int256 assetDelta,
        uint256 leverage,
        uint256 collateralValue
    ) internal view returns (uint256) {
        if (collateralValue == 0) return 0;

        address collateralToken = IBaseLooper(_strategy).collateralToken();

        int256 collateralDeltaAsset = (assetDelta * int256(leverage)) /
            int256(WAD);
        int256 collateralDelta = _assetToCollateralDelta(
            _strategy,
            collateralDeltaAsset
        );

        IAaveLooper looper = IAaveLooper(_strategy);
        (uint256 liquidityApr, ) = _calculateRates(
            looper.DATA_PROVIDER(),
            looper.POOL(),
            collateralToken,
            0,
            collateralDelta
        );

        uint256 underlyingCollateralApr = IGlobalAprOracle(GLOBAL_APR_ORACLE)
            .getStrategyApr(collateralToken, collateralDelta);

        return liquidityApr + underlyingCollateralApr;
    }

    function _calculateRates(
        IPoolDataProvider dataProvider,
        address pool,
        address reserve,
        int256 totalDebtDelta,
        int256 liquidityDelta
    ) internal view returns (uint256 liquidityApr, uint256 variableBorrowApr) {
        BorrowSnapshot memory snapshot = _getBorrowSnapshot(
            dataProvider,
            pool,
            reserve
        );
        if (
            snapshot.aTokenAddress == address(0) ||
            snapshot.interestRateStrategyAddress == address(0)
        ) return (0, 0);

        uint256 adjustedTotalDebt = snapshot.totalDebt;
        if (totalDebtDelta >= 0) {
            adjustedTotalDebt += uint256(totalDebtDelta);
        } else {
            uint256 debtReduction = uint256(-totalDebtDelta);
            if (debtReduction > adjustedTotalDebt) {
                debtReduction = adjustedTotalDebt;
            }
            adjustedTotalDebt -= debtReduction;
        }

        uint256 liquidityAdded;
        uint256 liquidityTaken;
        if (liquidityDelta >= 0) {
            liquidityAdded = uint256(liquidityDelta);
        } else {
            liquidityTaken = uint256(-liquidityDelta);
        }

        IReserveInterestRateStrategy.CalculateInterestRatesParams
            memory params = IReserveInterestRateStrategy
                .CalculateInterestRatesParams({
                    unbacked: snapshot.unbacked,
                    liquidityAdded: liquidityAdded,
                    liquidityTaken: liquidityTaken,
                    totalDebt: adjustedTotalDebt,
                    reserveFactor: snapshot.reserveFactor,
                    reserve: reserve,
                    usingVirtualBalance: snapshot.usingVirtualBalance,
                    virtualUnderlyingBalance: snapshot.virtualUnderlyingBalance
                });

        (
            uint256 liquidityRateRay,
            uint256 variableBorrowRateRay
        ) = IReserveInterestRateStrategy(snapshot.interestRateStrategyAddress)
                .calculateInterestRates(params);

        liquidityApr = liquidityRateRay / RAY_TO_WAD;
        variableBorrowApr = variableBorrowRateRay / RAY_TO_WAD;
    }

    function _getBorrowSnapshot(
        IPoolDataProvider dataProvider,
        address pool,
        address asset
    ) internal view returns (BorrowSnapshot memory snapshot) {
        (, , , , snapshot.reserveFactor, , , , , ) = dataProvider
            .getReserveConfigurationData(asset);
        (snapshot.unbacked, , , , , , , , , , , ) = dataProvider.getReserveData(
            asset
        );
        (snapshot.aTokenAddress, , ) = dataProvider.getReserveTokensAddresses(
            asset
        );

        snapshot.interestRateStrategyAddress = dataProvider
            .getInterestRateStrategyAddress(asset);
        snapshot.totalDebt = dataProvider.getTotalDebt(asset);
        snapshot.virtualUnderlyingBalance = IPool(pool)
            .getVirtualUnderlyingBalance(asset);
        snapshot.usingVirtualBalance = snapshot.virtualUnderlyingBalance > 0;
    }

    function _assetToCollateralDelta(
        address _strategy,
        int256 assetDelta
    ) internal view returns (int256) {
        if (assetDelta == 0) return 0;

        IAaveLooper looper = IAaveLooper(_strategy);
        address asset = IBaseLooper(_strategy).asset();
        address collateralToken = IBaseLooper(_strategy).collateralToken();

        uint256 collateralPrice = looper.AAVE_ORACLE().getAssetPrice(
            collateralToken
        );
        uint256 assetPrice = looper.AAVE_ORACLE().getAssetPrice(asset);
        if (collateralPrice == 0 || assetPrice == 0) return 0;

        uint256 assetDecimals = ERC20(asset).decimals();
        uint256 collateralDecimals = ERC20(collateralToken).decimals();

        uint256 numerator = assetPrice * (10 ** collateralDecimals);
        uint256 denominator = collateralPrice * (10 ** assetDecimals);

        return (assetDelta * int256(numerator)) / int256(denominator);
    }

    function _netApr(
        uint256 leverage,
        uint256 collateralApr,
        uint256 borrowApr
    ) internal pure returns (uint256) {
        if (leverage == 0) return 0;

        uint256 gross = (leverage * collateralApr) / WAD;
        uint256 cost = ((leverage - WAD) * borrowApr) / WAD;
        if (gross <= cost) return 0;

        return gross - cost;
    }
}
