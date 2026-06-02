// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

interface ICapToken {
    function mint(
        address _asset,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver,
        uint256 _deadline
    ) external returns (uint256 amountOut);

    function burn(
        address _asset,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver,
        uint256 _deadline
    ) external returns (uint256 amountOut);
}
