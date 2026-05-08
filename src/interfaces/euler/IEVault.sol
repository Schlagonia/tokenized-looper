// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IEVault {
    function asset() external view returns (address);

    function balanceOf(address account) external view returns (uint256);

    function totalAssets() external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function maxDeposit(address account) external view returns (uint256);

    function deposit(
        uint256 amount,
        address receiver
    ) external returns (uint256 shares);

    function withdraw(
        uint256 amount,
        address receiver,
        address owner
    ) external returns (uint256 shares);

    function totalBorrows() external view returns (uint256);

    function cash() external view returns (uint256);

    function debtOf(address account) external view returns (uint256);

    function borrow(
        uint256 amount,
        address receiver
    ) external returns (uint256 assets);

    function repay(
        uint256 amount,
        address receiver
    ) external returns (uint256 assets);

    function touch() external;

    function checkLiquidation(
        address liquidator,
        address violator,
        address collateral
    ) external view returns (uint256 maxRepay, uint256 maxYield);

    function accountLiquidity(
        address account,
        bool liquidation
    ) external view returns (uint256 collateralValue, uint256 liabilityValue);

    function caps() external view returns (uint16 supplyCap, uint16 borrowCap);

    function governorAdmin() external view returns (address);

    function setCaps(uint16 supplyCap, uint16 borrowCap) external;

    function LTVBorrow(address collateral) external view returns (uint16);

    function LTVLiquidation(address collateral) external view returns (uint16);

    function hookConfig()
        external
        view
        returns (address hookTarget, uint32 hookedOps);

    function EVC() external view returns (address);

    function unitOfAccount() external view returns (address);

    function oracle() external view returns (address);
}
