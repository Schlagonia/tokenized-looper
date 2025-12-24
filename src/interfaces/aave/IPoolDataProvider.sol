// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

/**
 * @title IPoolDataProvider
 * @notice Defines the basic interface for a PoolDataProvider
 */
interface IPoolDataProvider {
    /**
     * @notice Returns the user data in a reserve
     * @param asset The address of the underlying asset of the reserve
     * @param user The address of the user
     * @return currentATokenBalance The current AToken balance of the user
     * @return currentStableDebt The current stable debt of the user
     * @return currentVariableDebt The current variable debt of the user
     * @return principalStableDebt The principal stable debt of the user
     * @return scaledVariableDebt The scaled variable debt of the user
     * @return stableBorrowRate The stable borrow rate of the user
     * @return liquidityRate The liquidity rate of the reserve
     * @return stableRateLastUpdated The timestamp of the last stable rate update
     * @return usageAsCollateralEnabled True if the user is using the asset as collateral
     */
    function getUserReserveData(
        address asset,
        address user
    )
        external
        view
        returns (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40 stableRateLastUpdated,
            bool usageAsCollateralEnabled
        );

    /**
     * @notice Returns the configuration data of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return decimals The decimals of the asset
     * @return ltv The LTV of the asset (in basis points, e.g., 8000 = 80%)
     * @return liquidationThreshold The liquidation threshold (in basis points)
     * @return liquidationBonus The liquidation bonus (in basis points)
     * @return reserveFactor The reserve factor
     * @return usageAsCollateralEnabled True if the asset can be used as collateral
     * @return borrowingEnabled True if borrowing is enabled
     * @return stableBorrowRateEnabled True if stable borrow rate is enabled
     * @return isActive True if the reserve is active
     * @return isFrozen True if the reserve is frozen
     */
    function getReserveConfigurationData(
        address asset
    )
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        );

    /**
     * @notice Returns the caps parameters of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return borrowCap The borrow cap of the reserve (in whole tokens, 0 = no cap)
     * @return supplyCap The supply cap of the reserve (in whole tokens, 0 = no cap)
     */
    function getReserveCaps(
        address asset
    ) external view returns (uint256 borrowCap, uint256 supplyCap);

    /**
     * @notice Returns whether the reserve is paused
     * @param asset The address of the underlying asset
     * @return isPaused True if the reserve is paused
     */
    function getPaused(address asset) external view returns (bool isPaused);

    /**
     * @notice Returns the total supply of aTokens for a given asset
     * @param asset The address of the underlying asset of the reserve
     * @return The total supply of the aToken
     */
    function getATokenTotalSupply(
        address asset
    ) external view returns (uint256);

    /**
     * @notice Returns the total debt for a given asset
     * @param asset The address of the underlying asset of the reserve
     * @return The total debt (stable + variable)
     */
    function getTotalDebt(address asset) external view returns (uint256);

    /**
     * @notice Returns the token addresses of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return aTokenAddress The AToken address of the reserve
     * @return stableDebtTokenAddress The stable debt token address
     * @return variableDebtTokenAddress The variable debt token address
     */
    function getReserveTokensAddresses(
        address asset
    )
        external
        view
        returns (
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress
        );
}
