// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SideCarSwapper {
    using SafeERC20 for ERC20;

    struct SwapInstruction {
        address target;
        bytes data;
    }

    address public immutable STRATEGY;

    constructor(address _strategy) {
        STRATEGY = _strategy;
    }

    function executeSwap(
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _swapData
    ) external {
        require(msg.sender == STRATEGY, "!strategy");

        // Decode as raw tuple — abi.decode with named struct containing
        // dynamic types reverts under solc 0.8.23.
        (address target, bytes memory data) = abi.decode(
            _swapData,
            (address, bytes)
        );

        ERC20 fromToken = ERC20(_from);

        fromToken.forceApprove(target, _amount);

        (bool success, ) = target.call(data);

        fromToken.forceApprove(target, 0);
        require(success, "!swapData");

        uint256 fromBalance = fromToken.balanceOf(address(this));
        if (fromBalance != 0) fromToken.safeTransfer(msg.sender, fromBalance);

        uint256 toBalance = ERC20(_to).balanceOf(address(this));
        if (toBalance != 0) ERC20(_to).safeTransfer(msg.sender, toBalance);
    }
}
