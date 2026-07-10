// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title UniswapV3RouterExchange
 * @notice Venue-specific Uniswap V3 exchange for MetaExchange routes.
 */
contract UniswapV3RouterExchange is UniswapV3Swapper, BaseExchange {
    using SafeERC20 for ERC20;

    mapping(address => mapping(address => address)) public uniBases;

    event UniBaseSet(
        address indexed token0,
        address indexed token1,
        address indexed uniBase
    );

    constructor(
        address _base,
        address _router,
        address _governance
    ) BaseExchange(_governance) {
        require(_base != address(0), "!base");
        require(_router != address(0), "!router");
        base = _base;
        router = _router;
    }

    function name() external pure override returns (string memory) {
        return "UniswapV3RouterExchange";
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

    function setMinAmountToSell(
        address token,
        uint256 amount
    ) external onlyOperator {
        _setMinAmountToSell(token, amount);
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal override returns (uint256 amountOut) {
        address pairBase = uniBases[from][to];
        if (pairBase == address(0))
            return _swapFrom(from, to, amountIn, amountOutMin);

        address previousBase = base;
        base = pairBase;
        amountOut = _swapFrom(from, to, amountIn, amountOutMin);
        if (pairBase != previousBase) base = previousBase;
    }

    function _checkAllowance(
        address spender,
        address token,
        uint256 amount
    ) internal override {
        if (ERC20(token).allowance(address(this), spender) < amount) {
            ERC20(token).forceApprove(spender, type(uint256).max);
        }
    }
}
