// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IsUSDe {
    function cooldownShares(uint256 shares) external returns (uint256 assets);

    function unstake(address receiver) external;
}
