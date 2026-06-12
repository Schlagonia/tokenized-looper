// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IOUSDVault {
    struct WithdrawalQueueMetadata {
        uint128 queued;
        uint128 claimable;
        uint128 claimed;
        uint128 nextWithdrawalIndex;
    }

    struct WithdrawalRequest {
        address withdrawer;
        bool claimed;
        uint40 timestamp;
        uint128 amount;
        uint128 queued;
    }

    function asset() external view returns (address);

    function mint(uint256 amount) external;

    function requestWithdrawal(
        uint256 amount
    ) external returns (uint256 requestId, uint256 queued);

    function claimWithdrawal(
        uint256 requestId
    ) external returns (uint256 amount);

    function withdrawalClaimDelay() external view returns (uint256);

    function withdrawalQueueMetadata()
        external
        view
        returns (WithdrawalQueueMetadata memory);

    function withdrawalRequests(
        uint256 requestId
    ) external view returns (WithdrawalRequest memory);
}
