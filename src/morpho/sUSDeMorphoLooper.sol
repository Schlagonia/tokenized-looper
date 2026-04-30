// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {MorphoLooper, ERC20} from "./MorphoLooper.sol";
import {Id} from "../interfaces/morpho/IMorpho.sol";
import {IsUSDe} from "../interfaces/IsUSDe.sol";
import {IExchange} from "../interfaces/IExchange.sol";

/**
 * @title sUSDeMorphoLooper
 * @notice Morpho Blue looper using sUSDe as collateral. Adds the sUSDe
 *         cooldown state machine on top of `MorphoLooper`: emergency-only
 *         async unstake (`initiateCooldown` / `claimCooldown`) plus a path
 *         to convert the unstaked USDe back to the loan asset through the
 *         existing exchange wiring.
 */
contract sUSDeMorphoLooper is MorphoLooper {
    using SafeERC20 for ERC20;

    /// @notice The underlying token (USDe) that sUSDe wraps.
    address public immutable UNDERLYING;

    /// @notice Asset value queued for sUSDe cooldown — populated by
    ///         `initiateCooldown` and zeroed by `claimCooldown`.
    /// @dev Tracked in USDe units (returned by `cooldownShares`), not shares.
    uint256 public pendingRedemptions;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId,
        address _exchange,
        address _governance
    )
        MorphoLooper(
            _asset,
            _name,
            _collateralToken,
            _morpho,
            _marketId,
            _exchange,
            _governance
        )
    {
        UNDERLYING = IERC4626(_collateralToken).asset();
    }

    receive() external payable {}

    /// @notice Estimated total assets including any sUSDe queued for cooldown
    ///         and any loose USDe sitting in the strategy post-claim.
    /// @dev Pending USDe + loose USDe are translated back into asset terms by
    ///      first converting to equivalent sUSDe shares (so the same oracle-
    ///      based collateral pricing applies).
    function estimatedTotalAssets() public view override returns (uint256) {
        return
            super.estimatedTotalAssets() +
            _collateralToAsset(
                IERC4626(collateralToken).convertToShares(
                    pendingRedemptions + balanceOfUnderlying()
                )
            );
    }

    function balanceOfUnderlying() public view returns (uint256) {
        return ERC20(UNDERLYING).balanceOf(address(this));
    }

    /// @notice Block reports while a cooldown is in flight — the protocol's
    ///         queued payout isn't observable on-chain until `unstake`, so a
    ///         report run mid-flight would mismark.
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        require(pendingRedemptions == 0, "pending redemptions");
        return super._harvestAndReport();
    }

    /// @notice Queue loose sUSDe shares for the protocol cooldown.
    /// @dev Ethena's silo overrides existing cooldowns on a new request, so we
    ///      block until the prior queue is cleared via `claimCooldown` or
    ///      `zeroPendingRedemptions`.
    /// @param _shares sUSDe shares to send into cooldown.
    /// @return assets USDe that will be claimable after the cooldown window.
    function initiateCooldown(
        uint256 _shares
    ) external onlyEmergencyAuthorized returns (uint256 assets) {
        require(pendingRedemptions == 0, "pending redemptions");
        _shares = Math.min(_shares, balanceOfCollateralToken());

        assets = IsUSDe(collateralToken).cooldownShares(_shares);
        pendingRedemptions += assets;
    }

    /// @notice Pull queued USDe out of the cooldown silo into this strategy.
    function claimCooldown() external onlyEmergencyAuthorized {
        IsUSDe(collateralToken).unstake(address(this));
        pendingRedemptions = 0;
    }

    /// @notice Manually clear the pending tracker after a stuck/dust queue.
    /// @dev Pure bookkeeping — does not call into Ethena.
    function zeroPendingRedemptions() external onlyEmergencyAuthorized {
        pendingRedemptions = 0;
    }

    /// @notice Swap any loose USDe in the strategy back to the loan asset.
    /// @param amount USDe amount to convert (clamped to current balance).
    function convertUnderlyingToAsset(
        uint256 amount
    ) external onlyEmergencyAuthorized returns (uint256) {
        amount = Math.min(amount, balanceOfUnderlying());

        ERC20(UNDERLYING).forceApprove(exchange, amount);

        uint256 amountOut = IExchange(exchange).exchange(
            UNDERLYING,
            address(asset),
            amount,
            0
        );

        _recordSlippage(
            _collateralToAsset(
                IERC4626(collateralToken).convertToShares(amount)
            ),
            amountOut
        );
        return amountOut;
    }
}
