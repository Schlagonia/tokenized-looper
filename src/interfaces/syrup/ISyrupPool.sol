// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @notice Minimal interface for Maple Syrup pools used by the strategy.
 *         Pool shares are ERC4626 shares with async redemption helpers.
 */
interface ISyrupPool is IERC4626 {
    /**
     * @notice Queue shares for redemption.
     * @param shares The number of pool shares to redeem.
     * @param owner The owner of the shares.
     * @return exitShares Shares moved into the exit queue.
     */
    function requestRedeem(
        uint256 shares,
        address owner
    ) external returns (uint256 exitShares);

    /**
     * @notice Remove queued shares from redemption.
     * @param shares The number of queued shares to remove.
     * @param owner The owner of the queued shares.
     * @return removedShares Shares removed from the queue.
     */
    function removeShares(
        uint256 shares,
        address owner
    ) external returns (uint256 removedShares);
}
