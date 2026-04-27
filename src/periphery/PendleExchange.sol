// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PendleSwapper} from "@periphery/swappers/PendleSwapper.sol";

import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title PendleExchange
 * @notice Venue-specific Pendle exchange for MetaExchange routes.
 */
contract PendleExchange is PendleSwapper, BaseExchange {
    using SafeERC20 for ERC20;

    function setMinAmountToSell(uint256 minAmount) external onlyConfigOperator {
        _setMinAmountToSell(minAmount);
    }

    function setPendleMarket(address pt, address market) external onlyConfigOperator {
        require(pt != address(0) && market != address(0), "!market");
        _setMarket(pt, market);
    }

    function setGuessMaxMultiplier(uint256 multiplier) external onlyConfigOperator {
        _setGuessMaxMultiplier(multiplier);
    }

    function setPendleRouter(address _pendleRouter) external onlyConfigOperator {
        require(_pendleRouter != address(0), "!router");
        pendleRouter = _pendleRouter;
    }

    function _exchange(address from, address to, uint256 amountIn, uint256 amountOutMin)
        internal
        override
        returns (uint256 amountOut)
    {
        return _pendleSwapFrom(from, to, amountIn, amountOutMin);
    }

    function _checkAllowance(address spender, address token, uint256 amount) internal override {
        if (ERC20(token).allowance(address(this), spender) < amount) {
            ERC20(token).forceApprove(spender, type(uint256).max);
        }
    }
}
