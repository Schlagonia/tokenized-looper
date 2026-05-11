// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IsUSDe} from "../../interfaces/IsUSDe.sol";
import {BaseCooldownAdapter} from "./BaseCooldownAdapter.sol";

contract SUSDeCooldownAdapter is BaseCooldownAdapter {
    using SafeERC20 for ERC20;

    address public immutable UNDERLYING;
    uint256 public pendingRedemptions;

    constructor(address _strategy) BaseCooldownAdapter(_strategy) {
        UNDERLYING = IERC4626(collateralToken).asset();
    }

    function pendingValue() external view override returns (uint256) {
        uint256 amount = pendingRedemptions;
        if (amount == 0) return 0;

        return IERC4626(collateralToken).convertToShares(amount);
    }

    function tokenValue(
        address token,
        uint256 amount
    ) public view override returns (uint256) {
        if (token == UNDERLYING) {
            return IERC4626(collateralToken).convertToShares(amount);
        }
        return amount;
    }

    function initiate(
        uint256 collateralAmount,
        bytes calldata
    ) external override onlyStrategy returns (bytes memory) {
        require(pendingRedemptions == 0, "pending redemptions");
        require(collateralAmount > 0, "!shares");

        ERC20(collateralToken).safeTransferFrom(
            STRATEGY,
            address(this),
            collateralAmount
        );
        uint256 assets = IsUSDe(collateralToken).cooldownShares(
            collateralAmount
        );
        pendingRedemptions = assets;

        return abi.encode(assets);
    }

    function claim(
        bytes calldata
    ) external override onlyStrategy returns (bytes memory) {
        uint256 beforeBalance = ERC20(UNDERLYING).balanceOf(STRATEGY);
        IsUSDe(collateralToken).unstake(STRATEGY);
        uint256 assets = ERC20(UNDERLYING).balanceOf(STRATEGY) - beforeBalance;

        delete pendingRedemptions;
        return abi.encode(assets);
    }

    function clear(bytes calldata) external override onlyStrategy {
        delete pendingRedemptions;
    }
}
