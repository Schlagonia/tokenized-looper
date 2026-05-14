// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {UniswapUniversalSwapper} from "@periphery/swappers/UniswapUniversalSwapper.sol";

import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title UniswapUniversalRouterExchange
 * @notice Venue-specific Uniswap Universal Router exchange for MetaExchange routes.
 */
contract UniswapUniversalRouterExchange is
    UniswapUniversalSwapper,
    BaseExchange
{
    mapping(address => mapping(address => address)) public uniBases;

    event UniBaseSet(
        address indexed token0,
        address indexed token1,
        address indexed uniBase
    );

    constructor(
        address _weth,
        address _router,
        address _positionManager
    ) UniswapUniversalSwapper(_weth) {
        require(_router != address(0), "!router");
        require(_positionManager != address(0), "!positionManager");
        router = _router;
        positionManager = _positionManager;
    }

    function name() external pure override returns (string memory) {
        return "UniswapUniversalRouterExchange";
    }

    function setBase(address _base) external onlyOperator {
        require(_base != address(0), "!base");
        base = _base;
    }

    function setUniBaseForPair(
        address token0,
        address token1,
        address uniBase
    ) external onlyOperator {
        require(
            token0 != address(0) && token1 != address(0) && token0 != token1,
            "!pair"
        );

        uniBases[token0][token1] = uniBase;
        uniBases[token1][token0] = uniBase;

        emit UniBaseSet(token0, token1, uniBase);
    }

    function setUniFees(
        address token0,
        address token1,
        uint24 fee
    ) external onlyOperator {
        _setUniFees(token0, token1, fee);
    }

    function setV4Pool(
        address token0,
        address token1,
        bytes32 poolId
    ) external onlyOperator {
        _setV4Pool(token0, token1, poolId);
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal override returns (uint256 amountOut) {
        address pairBase = uniBases[from][to];
        if (pairBase == address(0)) {
            return _swapFrom(from, to, amountIn, amountOutMin);
        }

        address previousBase = base;
        base = pairBase;
        amountOut = _swapFrom(from, to, amountIn, amountOutMin);
        if (pairBase != previousBase) {
            base = previousBase;
        }
    }
}
