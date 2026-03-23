// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IBaseLooper} from "./IBaseLooper.sol";

interface IStrategyInterface is IStrategy, IBaseLooper {
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        bytes[] calldata swapData
    ) external returns (uint256 shares);

    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        bytes[] calldata swapData
    ) external returns (uint256 assets);
}
