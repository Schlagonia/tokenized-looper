// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IOracle {
    /// @notice Returns the price of 1 asset of collateral token quoted in 1 asset of loan token, scaled by 1e36.
    function price() external view returns (uint256);
}
