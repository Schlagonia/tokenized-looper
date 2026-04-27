// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISUSDS} from "../interfaces/sky/ISUSDS.sol";
import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title SUSDSExchange
 * @notice Venue-specific sUSDS deposit exchange for MetaExchange routes.
 */
contract SUSDSExchange is BaseExchange {
    using SafeERC20 for ERC20;

    uint16 public susdsReferral = 1007;

    function setSUSDSReferral(uint16 referral) external onlyGovernance {
        susdsReferral = referral;
    }

    function _exchange(address from, address vault, uint256 amountIn, uint256)
        internal
        override
        returns (uint256 amountOut)
    {
        require(IERC4626(vault).asset() == from, "!vaultAsset");

        ERC20(from).forceApprove(vault, amountIn);
        return ISUSDS(vault).deposit(amountIn, address(this), susdsReferral);
    }
}
