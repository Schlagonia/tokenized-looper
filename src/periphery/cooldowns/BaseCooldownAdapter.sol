// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";

abstract contract BaseCooldownAdapter {
    address public immutable STRATEGY;
    address public immutable asset;
    address public immutable collateralToken;

    modifier onlyStrategy() {
        require(msg.sender == STRATEGY, "!strategy");
        _;
    }

    constructor(address _strategy) {
        require(_strategy != address(0), "!strategy");
        STRATEGY = _strategy;
        asset = IStrategyInterface(STRATEGY).asset();
        collateralToken = IStrategyInterface(STRATEGY).collateralToken();
    }

    function pendingValue() external view virtual returns (uint256);

    function tokenValue(
        address token,
        uint256 amount
    ) public view virtual returns (uint256);

    function initiate(
        uint256 collateralAmount,
        bytes calldata data
    ) external virtual returns (bytes memory);

    function claim(bytes calldata) external virtual returns (bytes memory);

    function cancel(
        uint256,
        bytes calldata
    ) external virtual onlyStrategy returns (bytes memory) {
        revert("!cancel");
    }

    function clear(bytes calldata) external virtual onlyStrategy {}
}
