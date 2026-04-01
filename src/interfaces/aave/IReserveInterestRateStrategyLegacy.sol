// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IReserveInterestRateStrategyLegacy {
    struct CalculateInterestRatesParams {
        uint256 unbacked;
        uint256 liquidityAdded;
        uint256 liquidityTaken;
        uint256 totalStableDebt;
        uint256 totalVariableDebt;
        uint256 averageStableBorrowRate;
        uint256 reserveFactor;
        address reserve;
        address aToken;
    }

    function calculateInterestRates(
        CalculateInterestRatesParams memory params
    ) external view returns (uint256, uint256, uint256);
}
