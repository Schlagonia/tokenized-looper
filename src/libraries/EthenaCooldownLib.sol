// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExchange} from "../interfaces/IExchange.sol";
import {IsUSDe} from "../interfaces/IsUSDe.sol";

library EthenaCooldownLib {
    using SafeERC20 for ERC20;

    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant SUSDE =
        0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    function balanceOfUnderlying() external view returns (uint256) {
        return ERC20(USDE).balanceOf(address(this));
    }

    function initiate(uint256 shares) external returns (uint256 assets) {
        assets = IsUSDe(SUSDE).cooldownShares(shares);
    }

    function claim() external returns (uint256 assets) {
        uint256 preBalance = ERC20(USDE).balanceOf(address(this));
        IsUSDe(SUSDE).unstake(address(this));
        assets = ERC20(USDE).balanceOf(address(this)) - preBalance;
    }

    function convertUnderlyingToAsset(
        uint256 amount,
        address exchange,
        address asset
    ) external returns (uint256 shares, uint256 amountOut) {
        uint256 balance = ERC20(USDE).balanceOf(address(this));
        if (amount > balance) amount = balance;

        shares = IERC4626(SUSDE).convertToShares(amount);
        ERC20(USDE).forceApprove(exchange, amount);
        amountOut = IExchange(exchange).exchange(USDE, asset, amount, 0);
    }
}
