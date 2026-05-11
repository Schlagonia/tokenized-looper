// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IOUSD} from "../../interfaces/origin/IOUSD.sol";
import {IOUSDVault} from "../../interfaces/origin/IOUSDVault.sol";
import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title OriginMintExchange
 * @notice Venue-specific Origin mint exchange for MetaExchange routes.
 */
contract OriginMintExchange is BaseExchange {
    using SafeERC20 for ERC20;

    function name() external pure override returns (string memory) {
        return "OriginMintExchange";
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256
    ) internal override returns (uint256 amountOut) {
        address vault = IOUSD(to).vaultAddress();
        require(vault != address(0), "!vault");
        require(IOUSDVault(vault).asset() == from, "!vaultAsset");

        ERC20(from).forceApprove(vault, amountIn);

        uint256 balanceBefore = ERC20(to).balanceOf(address(this));
        IOUSDVault(vault).mint(amountIn);
        amountOut = ERC20(to).balanceOf(address(this)) - balanceBefore;
    }
}
