// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface ILitePSMWrapper {
    /// @notice Sell gem (USDC) and receive USDS.
    /// @param usr Recipient of the USDS.
    /// @param gemAmt Amount of gem (USDC, 6 decimals) to sell.
    /// @return usdsOut Amount of USDS received (18 decimals).
    function sellGem(
        address usr,
        uint256 gemAmt
    ) external returns (uint256 usdsOut);

    /// @notice Buy gem (USDC) using USDS.
    /// @param usr Recipient of the gem (USDC).
    /// @param gemAmt Amount of gem (USDC, 6 decimals) to buy.
    /// @return usdsIn Amount of USDS spent (18 decimals).
    function buyGem(
        address usr,
        uint256 gemAmt
    ) external returns (uint256 usdsIn);
}
