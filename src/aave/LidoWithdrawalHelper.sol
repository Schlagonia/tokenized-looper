// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IQueue, ISteth, IWETH} from "../interfaces/IStethInterfaces.sol";

contract LidoWithdrawalHelper {
    using SafeERC20 for ERC20;

    IQueue internal constant WITHDRAWAL_QUEUE =
        IQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);
    ISteth internal constant STETH =
        ISteth(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

    address public immutable strategy;
    address public immutable asset;

    constructor(address _strategy, address _asset) {
        strategy = _strategy;
        asset = _asset;
    }

    receive() external payable {}

    function initiate(
        uint256 _stETHAmount
    ) external returns (uint256 _requestId) {
        require(msg.sender == strategy, "!strat");
        require(
            _stETHAmount > WITHDRAWAL_QUEUE.MIN_STETH_WITHDRAWAL_AMOUNT(),
            "!minimum"
        );
        require(
            _stETHAmount <= WITHDRAWAL_QUEUE.MAX_STETH_WITHDRAWAL_AMOUNT(),
            "!maximum"
        );
        require(
            ERC20(address(STETH)).balanceOf(address(this)) >= _stETHAmount,
            "!amt"
        );
        ERC20(address(STETH)).forceApprove(address(WITHDRAWAL_QUEUE), 0);
        ERC20(address(STETH)).forceApprove(
            address(WITHDRAWAL_QUEUE),
            _stETHAmount
        );

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _stETHAmount;

        uint256[] memory requestIds = WITHDRAWAL_QUEUE.requestWithdrawals(
            amounts,
            address(this)
        );
        return requestIds[0];
    }

    function claim(
        uint256 _claimId,
        address _receiver
    ) external returns (uint256 _redeemedAmount) {
        require(msg.sender == strategy, "!strat");

        uint256 preBalance = address(this).balance;
        WITHDRAWAL_QUEUE.claimWithdrawal(_claimId);
        _redeemedAmount = address(this).balance - preBalance;

        IWETH(asset).deposit{value: _redeemedAmount}();
        ERC20(asset).safeTransfer(_receiver, _redeemedAmount);
    }
}
