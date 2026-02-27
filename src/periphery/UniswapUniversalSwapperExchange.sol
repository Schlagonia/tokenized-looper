// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {UniswapUniversalSwapper} from "@periphery/swappers/UniswapUniversalSwapper.sol";

import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title UniswapUniversalSwapperExchange
 * @notice Strategy-bound exchange wrapper using the universal swapper.
 *         - Only strategy can swap
 *         - Setters are onlyManagement via strategy.management()
 *         - Sweep is onlyGovernance via strategy factory governance
 *         - Base defaults to WETH from the parent constructor
 */
contract UniswapUniversalSwapperExchange is
    UniswapUniversalSwapper,
    BaseExchange
{
    using SafeERC20 for ERC20;

    constructor(address _weth) UniswapUniversalSwapper(_weth) {}

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
        base = _base;
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal override(BaseExchange) returns (uint256 amountOut) {
        return
            UniswapUniversalSwapper._swapFrom(from, to, amountIn, amountOutMin);
    }
}
