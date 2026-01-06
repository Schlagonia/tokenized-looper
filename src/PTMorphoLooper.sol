// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseMorphoLooper} from "./BaseMorphoLooper.sol";
import {Id} from "./interfaces/morpho/IMorpho.sol";
import {PendleSwapper} from "@periphery/swappers/PendleSwapper.sol";

/**
 * @title PTMorphoLooper
 * @notice Morpho looper using Pendle PT tokens as collateral.
 *         Uses flashloan-based leverage for atomic position management.
 *         - Deposits asset -> buys PT via Pendle AMM
 *         - Withdraws PT -> sells PT via Pendle AMM (or redeems post-expiry)
 *         - Uses Morpho Blue market with PT as collateral
 */
contract PTMorphoLooper is BaseMorphoLooper, PendleSwapper {
    using SafeERC20 for ERC20;

    /// @notice The Pendle market for PT swaps
    address public immutable pendleMarket;

    /// @notice The token used for Pendle swaps (may be same as asset)
    address public immutable pendleToken;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken, // PT token
        address _morpho,
        Id _marketId,
        address _pendleMarket,
        address _pendleToken
    ) BaseMorphoLooper(_asset, _name, _collateralToken, _morpho, _marketId) {
        targetLeverageRatio = 5e18;
        leverageBuffer = 0.25e18;
        maxLeverageRatio = 6e18;

        pendleMarket = _pendleMarket;
        pendleToken = _pendleToken;

        // Register PT with its Pendle market
        _setMarket(_collateralToken, _pendleMarket);

        uint256 ptDecimals = ERC20(_collateralToken).decimals();
        uint256 pendleTokenDecimals = ERC20(_pendleToken).decimals();

        // Start max guess max multiplier at 2x since we should only
        // be using like assets, but account for decimals.
        guessMaxMultiplier =
            2 *
            (10 **
                (
                    pendleTokenDecimals > ptDecimals
                        ? pendleTokenDecimals - ptDecimals
                        : ptDecimals - pendleTokenDecimals
                ));

        // Approve tokens for Pendle router
        ERC20(_pendleToken).forceApprove(pendleRouter, type(uint256).max);
        ERC20(_collateralToken).forceApprove(pendleRouter, type(uint256).max);
    }

    function setGuessMaxMultiplier(
        uint256 _multiplier
    ) external onlyManagement {
        _setGuessMaxMultiplier(_multiplier);
    }

    /*//////////////////////////////////////////////////////////////
                            CONVERSIONS
    //////////////////////////////////////////////////////////////*/

    function _convertAssetToCollateral(
        uint256 amount,
        uint256 amountOutMin
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        // Convert asset to pendleToken if different, then buy PT
        amount = _convertAssetToPendleToken(amount);
        return
            _pendleSwapFrom(pendleToken, collateralToken, amount, amountOutMin);
    }

    function _convertCollateralToAsset(
        uint256 amount,
        uint256 amountOutMin
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        // Sell PT for pendleToken, then convert to asset if different
        amount = _pendleSwapFrom(collateralToken, pendleToken, amount, 0);
        uint256 converted = _convertPendleTokenToAsset(amount);
        require(converted >= amountOutMin, "slippage");
        return converted;
    }

    /// @notice Convert asset to pendle token (override if different)
    /// @dev Default: asset == pendleToken, so no conversion needed
    function _convertAssetToPendleToken(
        uint256 amount
    ) internal virtual returns (uint256) {
        return amount;
    }

    /// @notice Convert pendle token to asset (override if different)
    /// @dev Default: asset == pendleToken, so no conversion needed
    function _convertPendleTokenToAsset(
        uint256 amount
    ) internal virtual returns (uint256) {
        return amount;
    }

    /*//////////////////////////////////////////////////////////////
                        NO-OP REWARDS (NONE)
    //////////////////////////////////////////////////////////////*/

    function _claimAndSellRewards() internal pure override {}
}
