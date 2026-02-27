// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBaseLooper} from "../interfaces/IBaseLooper.sol";
import {IExchange} from "../interfaces/IExchange.sol";

/**
 * @title BaseExchange
 * @notice Shared strategy-bound exchange primitives.
 *         Concrete exchanges override `_swapFrom` with their conversion logic.
 */
abstract contract BaseExchange is IExchange {
    using SafeERC20 for ERC20;

    /// @notice Bound strategy. Set exactly once after deployment.
    address public strategy;

    event StrategySet(address indexed strategy);

    modifier onlyStrategy() {
        require(msg.sender == strategy, "!strategy");
        _;
    }

    modifier onlyManagement() {
        require(
            msg.sender == IBaseLooper(strategy).management(),
            "!management"
        );
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == _governance(), "!governance");
        _;
    }

    /// @notice Bind strategy once. Must be called by the strategy itself.
    function setStrategy(address _strategy) external {
        require(strategy == address(0), "!strategy");
        require(_strategy != address(0), "!strategy");

        strategy = _strategy;
        emit StrategySet(_strategy);
    }

    function exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) external onlyStrategy returns (uint256 amountOut) {
        if (amountIn == 0) return 0;

        ERC20(from).safeTransferFrom(strategy, address(this), amountIn);
        amountOut = _exchange(from, to, amountIn, amountOutMin);
        require(amountOut >= amountOutMin, "!amountOut");

        ERC20(to).safeTransfer(strategy, amountOut);
    }

    function sweep(address token, uint256 amount) external onlyGovernance {
        require(token != address(0), "!token");
        address receiver = _governance();

        uint256 tokenToSweep = amount == type(uint256).max
            ? ERC20(token).balanceOf(address(this))
            : amount;
        ERC20(token).safeTransfer(receiver, tokenToSweep);
    }

    function _governance() internal view returns (address) {
        return IBaseLooper(strategy).GOVERNANCE();
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal virtual returns (uint256 amountOut);
}
