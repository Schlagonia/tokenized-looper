// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Governance} from "@periphery/utils/Governance.sol";
import {IExchange} from "../interfaces/IExchange.sol";

/**
 * @title BaseExchange
 * @notice Shared exchange primitives. Callers swap their own funds through the
 *         exchange; admin setters are governed separately.
 *         Concrete exchanges override `_exchange` with their conversion logic.
 */
abstract contract BaseExchange is IExchange, Governance, ReentrancyGuard {
    using SafeERC20 for ERC20;

    mapping(address => bool) public operators;

    event OperatorSet(address indexed operator, bool allowed);

    modifier onlyOperator() {
        require(operators[msg.sender] || msg.sender == governance, "!operator");
        _;
    }

    constructor(address _governance) Governance(_governance) {}

    function setOperator(
        address operator,
        bool allowed
    ) external onlyGovernance {
        require(operator != address(0), "!operator");
        operators[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    function name() external pure virtual override returns (string memory);

    function exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) return 0;

        ERC20(from).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = _exchange(from, to, amountIn, amountOutMin);
        require(amountOut >= amountOutMin, "!amountOut");

        ERC20(to).safeTransfer(msg.sender, amountOut);
    }

    function sweep(address token, uint256 amount) external onlyGovernance {
        require(token != address(0), "!token");

        uint256 tokenToSweep = amount == type(uint256).max
            ? ERC20(token).balanceOf(address(this))
            : amount;
        ERC20(token).safeTransfer(msg.sender, tokenToSweep);
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal virtual returns (uint256 amountOut);
}
