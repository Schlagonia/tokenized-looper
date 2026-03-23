// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IExchange {
    function strategy() external view returns (address);

    function setStrategy(address _strategy) external;

    function exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) external returns (uint256 amountOut);

    function exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes calldata data
    ) external returns (uint256 amountOut);
}
