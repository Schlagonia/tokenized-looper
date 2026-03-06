// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IReserveInterestRateStrategy {
    struct CalculateInterestRatesParams {
        uint256 unbacked;
        uint256 liquidityAdded;
        uint256 liquidityTaken;
        uint256 totalDebt;
        uint256 reserveFactor;
        address reserve;
        bool usingVirtualBalance;
        uint256 virtualUnderlyingBalance;
    }

    function calculateInterestRates(
        CalculateInterestRatesParams memory params
    ) external view returns (uint256, uint256);
}
