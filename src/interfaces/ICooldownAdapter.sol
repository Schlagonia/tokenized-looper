// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface ICooldownAdapter {
    function asset() external view returns (address);
    function collateralToken() external view returns (address);
    function UNDERLYING() external view returns (address);
    function pendingValue() external view returns (uint256);

    function tokenValue(
        address token,
        uint256 amount
    ) external view returns (uint256);

    function initiate(
        uint256 collateralAmount,
        bytes calldata data
    ) external returns (bytes memory);

    function claim(bytes calldata data) external returns (bytes memory);

    function cancel(
        uint256 amount,
        bytes calldata data
    ) external returns (bytes memory);

    function clear(bytes calldata data) external;
}
