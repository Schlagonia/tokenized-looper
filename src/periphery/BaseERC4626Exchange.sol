// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title BaseERC4626Exchange
 * @notice Shared vault routing logic for strategy-bound ERC-4626 exchanges.
 *         - `deposit = true`: routes into the vault by swapping to underlying and depositing
 *         - `redeem = true`: routes out of the vault by redeeming to underlying and swapping out
 *         - disabled paths fall back to share-token market swaps
 */
abstract contract BaseERC4626Exchange is BaseExchange {
    using SafeERC20 for ERC20;

    /// @notice Borrow token in the strategy (loan token).
    address public immutable ASSET;

    /// @notice ERC-4626 collateral share token.
    address public immutable COLLATERAL;

    /// @notice ERC-4626 underlying asset used by vault routing.
    address public immutable UNDERLYING;

    /// @notice Direct deposit toggle for routes into the vault.
    bool public deposit;

    /// @notice Direct redeem toggle for routes out of the vault.
    bool public redeem;

    constructor(address _asset, address _collateral) {
        require(_asset != address(0), "!asset");
        require(_collateral != address(0), "!collateral");

        ASSET = _asset;
        COLLATERAL = _collateral;
        UNDERLYING = IERC4626(_collateral).asset();
        require(UNDERLYING != address(0), "!underlying");

        ERC20(UNDERLYING).forceApprove(_collateral, type(uint256).max);
    }

    function setDeposit(bool _deposit) external onlyManagement {
        deposit = _deposit;
    }

    function setRedeem(bool _redeem) external onlyManagement {
        redeem = _redeem;
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal override(BaseExchange) returns (uint256 amountOut) {
        if (deposit && to == COLLATERAL && from != COLLATERAL) {
            uint256 underlyingAmount = from == UNDERLYING
                ? amountIn
                : _swapFrom(from, UNDERLYING, amountIn, 0);

            return
                IERC4626(COLLATERAL).deposit(underlyingAmount, address(this));
        }

        if (redeem && from == COLLATERAL && to != COLLATERAL) {
            uint256 underlyingAmount = IERC4626(COLLATERAL).redeem(
                amountIn,
                address(this),
                address(this)
            );

            return
                to == UNDERLYING
                    ? underlyingAmount
                    : _swapFrom(UNDERLYING, to, underlyingAmount, amountOutMin);
        }

        return _swapFrom(from, to, amountIn, amountOutMin);
    }

    function _swapFrom(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal virtual returns (uint256 amountOut);
}
