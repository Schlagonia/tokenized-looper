// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IPool {
    /**
     * @notice Supplies an `amount` of underlying asset into the reserve, receiving in return overlying aTokens.
     * @param asset The address of the underlying asset to supply
     * @param amount The amount to be supplied
     * @param onBehalfOf The address that will receive the aTokens
     * @param referralCode Code used to register the integrator originating the operation
     */
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /**
     * @notice Withdraws an `amount` of underlying asset from the reserve, burning the equivalent aTokens owned
     * @param asset The address of the underlying asset to withdraw
     * @param amount The underlying amount to be withdrawn (use type(uint256).max to withdraw the full balance)
     * @param to The address that will receive the underlying asset
     * @return The final amount withdrawn
     */
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);

    /**
     * @notice Allows users to borrow a specific `amount` of the reserve underlying asset
     * @param asset The address of the underlying asset to borrow
     * @param amount The amount to be borrowed
     * @param interestRateMode The interest rate mode: 1 for Stable, 2 for Variable
     * @param referralCode Code used to register the integrator originating the operation
     * @param onBehalfOf The address that will receive the debt (must be the msg.sender if debt is non-zero)
     */
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;

    /**
     * @notice Repays a borrowed `amount` on a specific reserve
     * @param asset The address of the borrowed underlying asset
     * @param amount The amount to repay (use type(uint256).max to repay the full debt)
     * @param interestRateMode The interest rate mode: 1 for Stable, 2 for Variable
     * @param onBehalfOf The address of the user whose debt is being repaid
     * @return The final amount repaid
     */
    function repay(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) external returns (uint256);

    /**
     * @notice Allows smartcontracts to access the liquidity of the pool within one transaction,
     * as long as the amount taken plus a fee is returned.
     * @param receiverAddress The address of the contract receiving the funds
     * @param asset The address of the asset being flash-borrowed
     * @param amount The amount of the asset being flash-borrowed
     * @param params Variadic packed params to pass to the receiver as extra information
     * @param referralCode Code used to register the integrator originating the operation
     */
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;

    /**
     * @notice Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralBase The total collateral of the user in the base currency
     * @return totalDebtBase The total debt of the user in the base currency
     * @return availableBorrowsBase The borrowing power left of the user in the base currency
     * @return currentLiquidationThreshold The liquidation threshold of the user
     * @return ltv The loan to value of the user
     * @return healthFactor The current health factor of the user
     */
    function getUserAccountData(
        address user
    )
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );

    /**
     * @notice Allows depositors to enable/disable a specific deposited asset as collateral
     * @param asset The address of the underlying asset deposited
     * @param useAsCollateral True to enable, false to disable
     */
    function setUserUseReserveAsCollateral(
        address asset,
        bool useAsCollateral
    ) external;

    /**
     * @notice Returns the state and configuration of the reserve
     * @param asset The address of the underlying asset of the reserve
     */
    function getReserveData(
        address asset
    )
        external
        view
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            uint16 id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        );

    /**
     * @notice Returns the total fee on flash loans
     * @return The total fee on flash loans (in bps, e.g., 5 = 0.05%)
     */
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);

    /**
     * @notice Allows a user to use the protocol in eMode
     * @param categoryId The id of the category (0 to exit eMode)
     */
    function setUserEMode(uint8 categoryId) external;

    /**
     * @notice Returns the eMode the user is using
     * @param user The address of the user
     * @return The eMode id
     */
    function getUserEMode(address user) external view returns (uint256);
}
