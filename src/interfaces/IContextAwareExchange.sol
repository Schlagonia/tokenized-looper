// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IContextAwareExchange {
    function exchangeWithContext(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        address context
    ) external returns (uint256 amountOut);
}
