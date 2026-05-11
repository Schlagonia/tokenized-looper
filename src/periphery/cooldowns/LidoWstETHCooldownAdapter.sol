// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISteth, IQueue, IWETH, IwstETH} from "../../interfaces/IStethInterfaces.sol";
import {BaseCooldownAdapter} from "./BaseCooldownAdapter.sol";

contract LidoWstETHCooldownAdapter is BaseCooldownAdapter {
    using SafeERC20 for ERC20;
    using SafeERC20 for ISteth;

    IQueue internal constant WITHDRAWAL_QUEUE =
        IQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);
    ISteth internal constant STETH =
        ISteth(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

    uint256 public pendingRedemptions;

    constructor(address _strategy) BaseCooldownAdapter(_strategy) {}

    receive() external payable {}

    function pendingValue() external view override returns (uint256) {
        uint256 stETHAmount = pendingRedemptions;
        if (stETHAmount == 0) return 0;

        return IwstETH(collateralToken).getWstETHByStETH(stETHAmount);
    }

    function tokenValue(
        address token,
        uint256 amount
    ) public view override returns (uint256) {
        if (token == address(STETH) || token == asset) {
            return IwstETH(collateralToken).getWstETHByStETH(amount);
        }

        return amount;
    }

    function initiate(
        uint256 collateralAmount,
        bytes calldata
    ) external override onlyStrategy returns (bytes memory) {
        require(collateralAmount > 0, "!amount");

        ERC20(collateralToken).safeTransferFrom(
            STRATEGY,
            address(this),
            collateralAmount
        );
        uint256 stETHAmount = IwstETH(collateralToken).unwrap(collateralAmount);
        pendingRedemptions += stETHAmount;

        ERC20(collateralToken).forceApprove(
            address(WITHDRAWAL_QUEUE),
            stETHAmount
        );

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = stETHAmount;

        uint256 requestId = WITHDRAWAL_QUEUE.requestWithdrawals(
            amounts,
            address(this)
        )[0];

        return abi.encode(requestId);
    }

    function claim(
        bytes calldata data
    ) external override onlyStrategy returns (bytes memory) {
        uint256 requestId = abi.decode(data, (uint256));

        uint256 preBalance = address(this).balance;
        WITHDRAWAL_QUEUE.claimWithdrawal(requestId);
        uint256 redeemedAmount = address(this).balance - preBalance;

        uint256 pending = pendingRedemptions;
        pendingRedemptions = redeemedAmount >= pending
            ? 0
            : pending - redeemedAmount;

        IWETH(asset).deposit{value: address(this).balance}();
        uint256 wethBalance = ERC20(asset).balanceOf(address(this));
        if (wethBalance != 0) {
            ERC20(asset).safeTransfer(STRATEGY, wethBalance);
        }

        return abi.encode(redeemedAmount);
    }

    function clear(bytes calldata) external override onlyStrategy {
        delete pendingRedemptions;
    }
}
