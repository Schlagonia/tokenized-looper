// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";

interface IBaseLooper is IBaseHealthCheck {
    function collateralToken() external view returns (address);

    /// @notice Target leverage ratio in WAD (e.g., 3e18 = 3x leverage)
    function targetLeverageRatio() external view returns (uint256);

    /// @notice Buffer tolerance in WAD for tend triggers
    /// @dev Bounds are implicitly [targetLeverageRatio - buffer, targetLeverageRatio + buffer]
    function leverageBuffer() external view returns (uint256);

    /// @notice Maximum leverage ratio in WAD (e.g., 10e18 = 10x leverage)
    /// Will trigger a tend if the current leverage ratio exceeds this value.
    function maxLeverageRatio() external view returns (uint256);

    function lastTend() external view returns (uint256);

    function minTendInterval() external view returns (uint256);

    function slippage() external view returns (uint64);

    function depositLimit() external view returns (uint256);

    function allowed(address _address) external view returns (bool);

    function maxGasPriceToTend() external view returns (uint256);

    function minAmountToBorrow() external view returns (uint256);

    /// @notice Maximum amount of asset to swap in a single tend
    function maxAmountToSwap() external view returns (uint256);

    function setAllowed(address _address, bool _allowed) external;

    function setDepositLimit(uint256 _depositLimit) external;

    function setMaxGasPriceToTend(uint256 _maxGasPriceToTend) external;

    function setSlippage(uint256 _slippage) external;

    function setMinAmountToBorrow(uint256 _minAmountToBorrow) external;

    function setMinTendInterval(uint256 _minTendInterval) external;

    function setMaxAmountToSwap(uint256 _maxAmountToSwap) external;

    function estimatedTotalAssets() external view returns (uint256);

    /// @notice Get current leverage ratio
    function getCurrentLeverageRatio() external view returns (uint256);

    /// @notice Get current LTV
    function getCurrentLTV() external view returns (uint256);

    /// @notice Get the liquidation LTV threshold from the protocol
    function getLiquidateCollateralFactor() external view returns (uint256);

    /// @notice Get balance of collateral in the lending protocol
    function balanceOfCollateral() external view returns (uint256);

    /// @notice Get balance of debt in the lending protocol
    function balanceOfDebt() external view returns (uint256);

    /// @notice Get balance of asset held by strategy
    function balanceOfAsset() external view returns (uint256);

    /// @notice Max available flashloan from protocol
    function maxFlashloan() external view returns (uint256);

    /// @notice Emergency full position close via flashloan
    function manualFullUnwind() external;

    /// @notice Manual: supply collateral (converts asset to collateral first)
    function manualSupplyCollateral(uint256 amount) external;

    /// @notice Manual: withdraw collateral (converts to asset)
    function manualWithdrawCollateral(uint256 amount) external;

    /// @notice Manual: borrow from protocol
    function manualBorrow(uint256 amount) external;

    /// @notice Manual: repay debt
    function manualRepay(uint256 amount) external;

    /// @notice Manual: convert collateral to asset
    function convertCollateralToAsset(uint256 amount) external;

    /// @notice Manual: convert asset to collateral
    function convertAssetToCollateral(uint256 amount) external;

    /// @notice Set target leverage ratio and buffer
    /// @param _targetLeverageRatio Target leverage in WAD (e.g., 3e18 = 3x)
    /// @param _leverageBuffer Buffer tolerance in WAD
    /// @param _maxLeverageRatio Maximum leverage ratio in WAD (e.g., 10e18 = 10x)
    function setLeverageParams(
        uint256 _targetLeverageRatio,
        uint256 _leverageBuffer,
        uint256 _maxLeverageRatio
    ) external;

    function position()
        external
        view
        returns (uint256 collateralValue, uint256 debt);
}
