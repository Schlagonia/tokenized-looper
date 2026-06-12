// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IRedeemController {
    function receiptToAsset(uint256 amount) external view returns (uint256);

    function userPendingClaims(address user) external view returns (uint256);

    function queueLength() external view returns (uint256);

    function liquidity() external view returns (uint256);
}
