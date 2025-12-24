// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

/**
 * @title IRewardsController
 * @notice Defines the basic interface for a Rewards Controller.
 */
interface IRewardsController {
    /**
     * @notice Claims all rewards for a user to the desired address, on all the assets of the pool
     * @param assets The list of assets to check eligible distributions (aTokens or variableDebtTokens)
     * @param to The address that will be receiving the rewards
     * @return rewardsList List of addresses of the reward tokens
     * @return claimedAmounts List that contains the claimed amount per reward
     */
    function claimAllRewards(
        address[] calldata assets,
        address to
    )
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);

    /**
     * @notice Claims all rewards for a user to msg.sender, on all the assets of the pool
     * @param assets The list of assets to check eligible distributions
     * @return rewardsList List of addresses of the reward tokens
     * @return claimedAmounts List that contains the claimed amount per reward
     */
    function claimAllRewardsToSelf(
        address[] calldata assets
    )
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);

    /**
     * @notice Returns the list of available reward token addresses for the given asset
     * @param asset The address of the incentivized asset
     * @return The list of rewards addresses
     */
    function getRewardsByAsset(
        address asset
    ) external view returns (address[] memory);

    /**
     * @notice Returns all the pending rewards for a user given a list of assets
     * @param assets The list of assets to check eligible distributions
     * @param user The address of the user
     * @return rewardsList List of addresses of the reward tokens
     * @return unclaimedAmounts List that contains the unclaimed amount per reward
     */
    function getAllUserRewards(
        address[] calldata assets,
        address user
    )
        external
        view
        returns (
            address[] memory rewardsList,
            uint256[] memory unclaimedAmounts
        );

    /**
     * @notice Returns the data for a specific reward token
     * @param asset The address of the incentivized asset
     * @param reward The address of the reward token
     * @return index The reward index
     * @return emissionPerSecond The emission per second
     * @return lastUpdateTimestamp The last update timestamp
     * @return distributionEnd The distribution end timestamp
     */
    function getRewardsData(
        address asset,
        address reward
    )
        external
        view
        returns (
            uint256 index,
            uint256 emissionPerSecond,
            uint256 lastUpdateTimestamp,
            uint256 distributionEnd
        );
}
