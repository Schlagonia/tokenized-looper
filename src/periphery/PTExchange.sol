// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PendleSwapper} from "@periphery/swappers/PendleSwapper.sol";
import {IPMarket, IPPrincipalToken, IStandardizedYield} from "@periphery/interfaces/Pendle/IPendle.sol";

import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title PTExchange
 * @notice Strategy-bound exchange for asset <-> Pendle PT collateral.
 *         Default flow assumes asset == pendleToken.
 */
contract PTExchange is BaseExchange, PendleSwapper {
    /// @notice Borrow asset token used by strategy.
    address public immutable ASSET;

    /// @notice PT collateral token used by strategy.
    address public immutable COLLATERAL;

    /// @notice Pendle market for this PT.
    address public immutable PENDLE_MARKET;

    /// @notice Token used for Pendle swaps (may differ from ASSET).
    address public immutable PENDLE_TOKEN;

    constructor(
        address _asset,
        address _collateral,
        address _pendleMarket,
        address _pendleToken
    ) {
        require(_asset != address(0), "!asset");
        require(_collateral != address(0), "!collateral");
        require(_pendleMarket != address(0), "!market");
        require(_pendleToken != address(0), "!pendleToken");

        (IStandardizedYield sy, IPPrincipalToken pt, ) = IPMarket(_pendleMarket)
            .readTokens();
        require(address(pt) == _collateral, "!marketPT");
        require(_isTokenIn(_pendleToken, sy.getTokensIn()), "!tokenIn");

        ASSET = _asset;
        COLLATERAL = _collateral;
        PENDLE_MARKET = _pendleMarket;
        PENDLE_TOKEN = _pendleToken;

        _setMarket(_collateral, _pendleMarket);

        uint256 ptDecimals = ERC20(_collateral).decimals();
        uint256 pendleTokenDecimals = ERC20(_pendleToken).decimals();
        guessMaxMultiplier =
            2 *
            (10 **
                (
                    pendleTokenDecimals > ptDecimals
                        ? pendleTokenDecimals - ptDecimals
                        : ptDecimals - pendleTokenDecimals
                ));
    }

    function setGuessMaxMultiplier(
        uint256 _multiplier
    ) external onlyManagement {
        _setGuessMaxMultiplier(_multiplier);
    }

    function setPendleRouter(address _pendleRouter) external onlyManagement {
        require(_pendleRouter != address(0), "!router");
        pendleRouter = _pendleRouter;
    }

    function setMinAmountToSell(
        uint256 _minAmountToSell
    ) external onlyManagement {
        _setMinAmountToSell(_minAmountToSell);
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal virtual override returns (uint256 amountOut) {
        if (from == ASSET && to == COLLATERAL) {
            uint256 pendleAmount = _convertAssetToPendleToken(amountIn);
            return
                _pendleSwapFrom(
                    PENDLE_TOKEN,
                    COLLATERAL,
                    pendleAmount,
                    amountOutMin
                );
        } else if (from == COLLATERAL && to == ASSET) {
            uint256 pendleAmount = _pendleSwapFrom(
                COLLATERAL,
                PENDLE_TOKEN,
                amountIn,
                0
            );
            return _convertPendleTokenToAsset(pendleAmount);
        } else {
            revert("!path");
        }
    }

    function _convertAssetToPendleToken(
        uint256 amount
    ) internal virtual returns (uint256) {
        return amount;
    }

    function _convertPendleTokenToAsset(
        uint256 amount
    ) internal virtual returns (uint256) {
        return amount;
    }

    function _isTokenIn(
        address token,
        address[] memory tokensIn
    ) internal pure returns (bool) {
        uint256 length = tokensIn.length;
        for (uint256 i; i < length; ) {
            if (tokensIn[i] == token) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }
}
