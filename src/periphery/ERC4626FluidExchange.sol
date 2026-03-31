// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {FluidSwapper} from "@periphery/swappers/FluidSwapper.sol";

import {BaseERC4626Exchange} from "./BaseERC4626Exchange.sol";

/**
 * @title ERC4626FluidExchange
 * @notice Strategy-bound ERC-4626 exchange using Fluid routes.
 */
contract ERC4626FluidExchange is FluidSwapper, BaseERC4626Exchange {
    constructor(
        address _weth,
        address _base,
        address _asset,
        address _collateral
    ) FluidSwapper(_weth) BaseERC4626Exchange(_asset, _collateral) {
        require(_base != address(0), "!base");
        base = _base;
    }

    function setBase(address _base) external onlyManagement {
        require(_base != address(0), "!base");
        base = _base;
    }

    function setFluidDex(
        address _token0,
        address _token1,
        address _dex
    ) external onlyManagement {
        _setFluidDex(_token0, _token1, _dex);
    }

    function setFluidDex(
        address _from,
        address _to,
        address _dex,
        bool _swap0to1
    ) external onlyManagement {
        _setFluidDex(_from, _to, _dex, _swap0to1);
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
        return _fluidSwapFrom(from, to, amountIn, amountOutMin);
    }
}
