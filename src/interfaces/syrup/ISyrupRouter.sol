// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

/**
 * @notice Minimal Maple Syrup Router interface used by SyrupExchange.
 * @dev Router address depends on the syrup pool (e.g. syrupUSDC/syrupUSDT).
 */
interface ISyrupRouter {
    function poolManager() external view returns (address);

    function poolPermissionManager() external view returns (address);

    /**
     * @notice Deposit assets through Maple's router into a syrup pool.
     * @param amount Asset amount to deposit.
     * @param depositData Pool-specific deposit metadata provided by Maple.
     * @return amountOut Router-reported share amount.
     */
    function deposit(
        uint256 amount,
        bytes32 depositData
    ) external returns (uint256 amountOut);

    /**
     * @notice Authorize the caller for Maple pool deposits, then deposit.
     * @dev Used for first-time contract deposits when `P:deposit` is not yet set.
     */
    function authorizeAndDeposit(
        uint256 amount,
        bytes32 depositData,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountOut);
}
