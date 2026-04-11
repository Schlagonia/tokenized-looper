// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {CurveSwapper} from "@periphery/swappers/CurveSwapper.sol";

import {BaseERC4626Exchange} from "./BaseERC4626Exchange.sol";

/**
 * @title ERC4626CurveExchange
 * @notice Strategy-bound ERC-4626 exchange using Curve Router NG routes.
 */
contract ERC4626CurveExchange is CurveSwapper, BaseERC4626Exchange {
    constructor(
        address _asset,
        address _collateral
    ) BaseERC4626Exchange(_asset, _collateral) {}

    function setCurveRouter(address _curveRouter) external onlyManagement {
        require(_curveRouter != address(0), "!router");
        curveRouter = _curveRouter;
    }

    function setCurveRoute(
        address _from,
        address _to,
        address[11] memory _route,
        uint256[5][5] memory _swapParams,
        address[5] memory _pools
    ) external onlyManagement {
        _setCurveRoute(_from, _to, _route, _swapParams, _pools);
    }

    function setMinAmountToSell(
        uint256 _minAmountToSell
    ) external onlyManagement {
        _setMinAmountToSell(_minAmountToSell);
    }

    function _swapFrom(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    )
        internal
        virtual
        override(BaseERC4626Exchange)
        returns (uint256 amountOut)
    {
        return _curveSwapFrom(from, to, amountIn, amountOutMin);
    }
}
