// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

/**
 * @title IAToken
 * @notice Minimal interface for Aave V3 aToken to get incentives controller
 */
interface IAToken {
    /**
     * @notice Returns the address of the Incentives Controller contract
     * @return The address of the Incentives Controller
     */
    function getIncentivesController() external view returns (address);
}
