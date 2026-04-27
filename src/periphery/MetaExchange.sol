// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExchange} from "../interfaces/IExchange.sol";
import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title MetaExchange
 * @notice Route-driven exchange hub. Each route step links to another
 *         IExchange-compatible contract that executes one swap primitive.
 */
contract MetaExchange is BaseExchange {
    using SafeERC20 for ERC20;

    struct RouteStep {
        address exchange;
        address tokenTo;
    }

    address public immutable weth;

    mapping(address => bool) public allowedExchanges;
    mapping(address => mapping(address => RouteStep[])) internal _routes;

    event AllowedExchangeSet(address indexed exchange, bool allowed);
    event RouteSet(address indexed from, address indexed to, uint256 length);

    constructor(address _weth) {
        require(_weth != address(0), "!weth");
        weth = _weth;
    }

    function getRoute(address from, address to) external view returns (RouteStep[] memory) {
        return _routes[from][to];
    }

    function setAllowedExchange(address exchange, bool allowed) external onlyGovernance {
        require(exchange != address(0), "!exchange");
        allowedExchanges[exchange] = allowed;
        emit AllowedExchangeSet(exchange, allowed);
    }

    function setRoute(address from, address to, RouteStep[] calldata route) external onlyConfigOperator {
        require(from != address(0) && to != address(0), "!token");

        delete _routes[from][to];

        uint256 length = route.length;
        if (length == 0) {
            emit RouteSet(from, to, 0);
            return;
        }

        require(route[length - 1].tokenTo == to, "!route");

        for (uint256 i; i < length;) {
            RouteStep calldata step = route[i];
            require(step.exchange != address(0), "!exchange");
            require(allowedExchanges[step.exchange], "!allowed");
            require(step.tokenTo != address(0), "!tokenTo");
            _routes[from][to].push(step);
            unchecked {
                ++i;
            }
        }

        emit RouteSet(from, to, length);
    }

    function _exchange(address from, address to, uint256 amountIn, uint256)
        internal
        override
        returns (uint256 amountOut)
    {
        if (from == to) return amountIn;

        RouteStep[] storage route = _routes[from][to];
        uint256 length = route.length;
        require(length != 0, "!route");

        address currentToken = from;
        amountOut = amountIn;

        for (uint256 i; i < length;) {
            RouteStep storage step = route[i];
            require(allowedExchanges[step.exchange], "!allowed");
            _checkAllowance(step.exchange, currentToken, amountOut);
            amountOut = IExchange(step.exchange).exchange(currentToken, step.tokenTo, amountOut, 0);
            currentToken = step.tokenTo;
            unchecked {
                ++i;
            }
        }

        require(currentToken == to, "!route");
    }

    function _checkAllowance(address spender, address token, uint256 amount) internal {
        if (ERC20(token).allowance(address(this), spender) < amount) {
            ERC20(token).forceApprove(spender, type(uint256).max);
        }
    }
}
