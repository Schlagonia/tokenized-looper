// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IStakedToken {
    function totalAssets() external view returns (uint256);

    function epochRewards(uint256 epoch) external view returns (uint256);

    function yieldSharing() external view returns (address);
}
