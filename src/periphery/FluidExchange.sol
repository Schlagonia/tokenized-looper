// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {FluidSwapper} from "@periphery/swappers/FluidSwapper.sol";

import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title FluidExchange
 * @notice Strategy-bound exchange wrapper using FluidSwapper routes.
 *         - Any caller can swap its own funds through the exchange
 *         - Setters are onlyManagement via exchange governance
 *         - Sweep is onlyGovernance
 */
contract FluidExchange is FluidSwapper, BaseExchange {
    constructor(address _weth) FluidSwapper(_weth) {}

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
    ) internal override(BaseExchange) returns (uint256 amountOut) {
        return _fluidSwapFrom(from, to, amountIn, amountOutMin);
    }
}
