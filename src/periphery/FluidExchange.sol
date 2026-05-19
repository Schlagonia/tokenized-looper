// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {FluidSwapper} from "@periphery/swappers/FluidSwapper.sol";

import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title FluidExchange
 * @notice Venue-specific Fluid exchange for MetaExchange routes.
 */
contract FluidExchange is FluidSwapper, BaseExchange {
    mapping(address => mapping(address => address)) public fluidBases;

    event FluidBaseSet(
        address indexed token0,
        address indexed token1,
        address indexed fluidBase
    );

    constructor(
        address _weth,
        address _governance
    ) FluidSwapper(_weth) BaseExchange(_governance) {}

    function name() external pure override returns (string memory) {
        return "FluidExchange";
    }

    function setBase(address _base) external onlyOperator {
        require(_base != address(0), "!base");
        base = _base;
    }

    function setFluidBaseForPair(
        address token0,
        address token1,
        address _fluidBase
    ) external onlyOperator {
        require(
            token0 != address(0) && token1 != address(0) && token0 != token1,
            "!pair"
        );

        fluidBases[token0][token1] = _fluidBase;
        fluidBases[token1][token0] = _fluidBase;

        emit FluidBaseSet(token0, token1, _fluidBase);
    }

    function setFluidDex(
        address token0,
        address token1,
        address dex
    ) external onlyOperator {
        _setFluidDex(token0, token1, dex);
    }

    function setFluidDex(
        address _from,
        address _to,
        address _dex,
        bool _swap0to1
    ) external onlyOperator {
        _setFluidDex(_from, _to, _dex, _swap0to1);
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal override returns (uint256 amountOut) {
        address pairBase = fluidBases[from][to];
        if (pairBase == address(0)) {
            return _fluidSwapFrom(from, to, amountIn, amountOutMin);
        }

        address previousBase = base;
        base = pairBase;
        amountOut = _fluidSwapFrom(from, to, amountIn, amountOutMin);
        if (pairBase != previousBase) {
            base = previousBase;
        }
    }
}
