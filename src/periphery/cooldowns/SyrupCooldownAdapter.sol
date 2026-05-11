// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ISyrupPool} from "../../interfaces/syrup/ISyrupPool.sol";
import {BaseCooldownAdapter} from "./BaseCooldownAdapter.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SyrupCooldownAdapter is BaseCooldownAdapter {
    using SafeERC20 for ERC20;

    address public immutable UNDERLYING;

    uint256 public pendingRedemptionShares;

    constructor(address _strategy) BaseCooldownAdapter(_strategy) {
        UNDERLYING = ISyrupPool(collateralToken).asset();
    }

    function pendingValue() external view override returns (uint256) {
        return pendingRedemptionShares;
    }

    function tokenValue(
        address token,
        uint256 amount
    ) public view override returns (uint256) {
        if (token == UNDERLYING) {
            return ISyrupPool(collateralToken).convertToShares(amount);
        }

        return amount;
    }

    function initiate(
        uint256 collateralAmount,
        bytes calldata
    ) external override onlyStrategy returns (bytes memory) {
        require(collateralAmount > 0, "!shares");

        ERC20(collateralToken).safeTransferFrom(
            STRATEGY,
            address(this),
            collateralAmount
        );

        uint256 exitShares = ISyrupPool(collateralToken).requestRedeem(
            collateralAmount,
            address(this)
        );
        pendingRedemptionShares += exitShares;

        return abi.encode(exitShares);
    }

    function claim(
        bytes calldata data
    ) external override onlyStrategy returns (bytes memory) {
        uint256 balance = ERC20(UNDERLYING).balanceOf(address(this));
        require(balance > 0, "!balance");

        ERC20(UNDERLYING).safeTransfer(STRATEGY, balance);

        uint256 shares = abi.decode(data, (uint256));
        pendingRedemptionShares = shares < pendingRedemptionShares
            ? pendingRedemptionShares - shares
            : 0;
        return abi.encode(balance);
    }

    function cancel(
        uint256 shares,
        bytes calldata
    ) external override onlyStrategy returns (bytes memory) {
        uint256 pending = pendingRedemptionShares;
        shares = shares == type(uint256).max ? pending : shares;
        require(shares > 0, "!shares");

        uint256 removedShares = ISyrupPool(collateralToken).removeShares(
            shares,
            address(this)
        );
        pendingRedemptionShares = removedShares >= pending
            ? 0
            : pending - removedShares;

        ERC20(collateralToken).safeTransfer(STRATEGY, removedShares);

        return abi.encode(removedShares);
    }

    function clear(bytes calldata) external override onlyStrategy {
        delete pendingRedemptionShares;
    }
}
