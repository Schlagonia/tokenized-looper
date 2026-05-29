// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MorphoLooper} from "./MorphoLooper.sol";
import {Id} from "../interfaces/morpho/IMorpho.sol";
import {IExchange} from "../interfaces/IExchange.sol";
import {IsUSDe} from "../interfaces/IsUSDe.sol";

/**
 * @title sUSDeMorphoLooper
 * @notice Morpho Blue looper using sUSDe as collateral. Adds the sUSDe
 *         cooldown state machine on top of `MorphoLooper`: management-only
 *         async unstake (`initiateCooldown` / `claimCooldown`) plus a path
 *         to convert the unstaked USDe back to the loan asset through the
 *         existing exchange wiring.
 */
contract sUSDeMorphoLooper is MorphoLooper {
    using SafeERC20 for ERC20;

    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant SUSDE =
        0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

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
    {}

    function totalCollateralBalance() public view override returns (uint256) {
        return
            super.totalCollateralBalance() +
            IERC4626(collateralToken).convertToShares(
                pendingRedemptions + balanceOfUnderlying()
            );
    }

    function balanceOfUnderlying() public view returns (uint256) {
        return ERC20(USDE).balanceOf(address(this));
    }

    function protectedTokens()
        public
        view
        override
        returns (address[] memory _protected)
    {
        _protected = new address[](3);
        _protected[0] = address(asset);
        _protected[1] = collateralToken;
        _protected[2] = USDE;
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
    ) external onlyManagement returns (uint256 assets) {
        require(pendingRedemptions == 0, "pending redemptions");
        _shares = Math.min(_shares, balanceOfCollateralToken());

        require(_shares > 0, "!shares");
        assets = IsUSDe(SUSDE).cooldownShares(_shares);
        pendingRedemptions = assets;
    }

    /// @notice Pull queued USDe out of the cooldown silo into this strategy.
    function claimCooldown() external onlyKeepers {
        _claimCooldown();
        pendingRedemptions = 0;
    }

    /// @notice Manually clear the pending tracker after a stuck/dust queue.
    /// @dev Pure bookkeeping — does not call into Ethena.
    function zeroPendingRedemptions() external onlyManagement {
        pendingRedemptions = 0;
    }

    /// @notice Swap any loose USDe in the strategy back to the loan asset.
    /// @param amount USDe amount to convert (clamped to current balance).
    function convertUnderlyingToAsset(
        uint256 amount
    ) external onlyKeepers returns (uint256) {
        uint256 balance = ERC20(USDE).balanceOf(address(this));
        if (amount > balance) amount = balance;

        uint256 shares = IERC4626(SUSDE).convertToShares(amount);
        _updateSlippageLossLimit();
        ERC20(USDE).forceApprove(exchange, amount);
        uint256 amountOut = IExchange(exchange).exchange(
            USDE,
            address(asset),
            amount,
            0
        );

        _recordSlippage(_collateralToAsset(shares), amountOut);
        return amountOut;
    }

    function _claimCooldown() internal returns (uint256 assets) {
        uint256 preBalance = ERC20(USDE).balanceOf(address(this));
        IsUSDe(SUSDE).unstake(address(this));
        assets = ERC20(USDE).balanceOf(address(this)) - preBalance;
    }
}
