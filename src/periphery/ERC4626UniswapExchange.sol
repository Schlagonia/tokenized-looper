// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {UniswapUniversalSwapper} from "@periphery/swappers/UniswapUniversalSwapper.sol";

import {BaseERC4626Exchange} from "./BaseERC4626Exchange.sol";

/**
 * @title ERC4626UniswapExchange
 * @notice Strategy-bound ERC-4626 exchange using the Uniswap Universal Router.
 */
contract ERC4626UniswapExchange is
    UniswapUniversalSwapper,
    BaseERC4626Exchange
{
    constructor(
        address _weth,
        address _base,
        address _asset,
        address _collateral
    ) UniswapUniversalSwapper(_weth) BaseERC4626Exchange(_asset, _collateral) {
        require(_base != address(0), "!base");
        base = _base;
    }

    function setUniFees(
        address _token0,
        address _token1,
        uint24 _fee
    ) external onlyManagement {
        _setUniFees(_token0, _token1, _fee);
    }

    function setV4Pool(
        address _token0,
        address _token1,
        bytes32 _poolId
    ) external onlyManagement {
        _setV4Pool(_token0, _token1, _poolId);
    }

    function setBase(address _base) external onlyManagement {
        require(_base != address(0), "!base");
        base = _base;
    }

    function _swapFrom(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    )
        internal
        virtual
        override(BaseERC4626Exchange, UniswapUniversalSwapper)
        returns (uint256 amountOut)
    {
        return
            UniswapUniversalSwapper._swapFrom(from, to, amountIn, amountOutMin);
    }
}
