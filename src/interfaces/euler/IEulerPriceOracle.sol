// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IEulerPriceOracle {
    function getQuote(
        uint256 inAmount,
        address base,
        address quote
    ) external view returns (uint256 outAmount);
}
