// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AaveStrategyAprOracle} from "./AaveStrategyAprOracle.sol";
import {IReserveInterestRateStrategyLegacy} from "../interfaces/aave/IReserveInterestRateStrategyLegacy.sol";

contract SparkStrategyAprOracle is AaveStrategyAprOracle {
    constructor(address _governance) AaveStrategyAprOracle(_governance) {
        name = "Spark Looper Strategy Apr Oracle";
    }

    function _calculateInterestRates(
        BorrowSnapshot memory snapshot,
        address reserve,
        uint256 liquidityAdded,
        uint256 liquidityTaken,
        uint256 adjustedTotalVariableDebt
    )
        internal
        view
        override
        returns (uint256 liquidityRateRay, uint256 variableBorrowRateRay)
    {
        IReserveInterestRateStrategyLegacy.CalculateInterestRatesParams
            memory params = IReserveInterestRateStrategyLegacy
                .CalculateInterestRatesParams({
                    unbacked: snapshot.unbacked,
                    liquidityAdded: liquidityAdded,
                    liquidityTaken: liquidityTaken,
                    totalStableDebt: snapshot.totalStableDebt,
                    totalVariableDebt: adjustedTotalVariableDebt,
                    averageStableBorrowRate: snapshot.averageStableBorrowRate,
                    reserveFactor: snapshot.reserveFactor,
                    reserve: reserve,
                    aToken: snapshot.aTokenAddress
                });

        (
            liquidityRateRay,
            ,
            variableBorrowRateRay
        ) = IReserveInterestRateStrategyLegacy(
            snapshot.interestRateStrategyAddress
        ).calculateInterestRates(params);
    }
}
