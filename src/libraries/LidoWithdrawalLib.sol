// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IQueue, IWETH, IwstETH} from "../interfaces/IStethInterfaces.sol";

library LidoWithdrawalLib {
    using SafeERC20 for ERC20;

    address internal constant STETH =
        0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH =
        0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WITHDRAWAL_QUEUE =
        0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    function initiate(
        uint256 amount
    ) external returns (uint256 requestId, uint256 pendingAssets) {
        uint256 balance = ERC20(WSTETH).balanceOf(address(this));
        if (amount > balance) amount = balance;

        pendingAssets = IwstETH(WSTETH).unwrap(amount);
        ERC20(STETH).forceApprove(WITHDRAWAL_QUEUE, pendingAssets);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = pendingAssets;

        requestId = IQueue(WITHDRAWAL_QUEUE).requestWithdrawals(
            amounts,
            address(this)
        )[0];
    }

    function claim(uint256 requestId) external returns (uint256 assets) {
        uint256 preBalance = IWETH(WETH).balanceOf(address(this));
        IQueue(WITHDRAWAL_QUEUE).claimWithdrawal(requestId);
        if (address(this).balance > 0) {
            IWETH(WETH).deposit{value: address(this).balance}();
        }
        assets = IWETH(WETH).balanceOf(address(this)) - preBalance;
    }
}
