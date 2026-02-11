// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract BaseExchange {
    using SafeERC20 for ERC20;

    function exchange(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata data
    ) external virtual returns (uint256 amountOut) {
        amountOut = _exchange(tokenIn, tokenOut, amountIn, data);
        _sweep(tokenIn);
        _sweep(tokenOut);
    }

    function _exchange(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata data) internal virtual returns (uint256 amountOut);


    function _sweep(address token) internal virtual {
        uint256 balance = ERC20(token).balanceOf(address(this));
        if (balance > 0) {
            ERC20(token).safeTransfer(msg.sender, balance);
        }
    }
}