// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IContextAwareExchange} from "../interfaces/IContextAwareExchange.sol";
import {IExchange} from "../interfaces/IExchange.sol";
import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title MetaExchange
 * @notice Route-driven exchange hub. Each route step links to a venue
 *         contract that executes one swap primitive.
 */
contract MetaExchange is BaseExchange {
    using SafeERC20 for ERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct RouteStep {
        address exchange;
        address tokenFrom;
        address tokenTo;
    }

    mapping(address => bool) public allowedExchanges;
    mapping(address => bool) public contextAwareExchanges;
    EnumerableSet.AddressSet internal _allowedExchangeSet;
    mapping(address => mapping(address => RouteStep[])) internal _routes;

    event AllowedExchangeSet(address indexed exchange, bool allowed);
    event ContextAwareExchangeSet(address indexed exchange, bool allowed);
    event RouteSet(address indexed from, address indexed to, uint256 length);

    constructor(address _governance) BaseExchange(_governance) {}

    function name() external pure override returns (string memory) {
        return "MetaExchange";
    }

    function getRoute(
        address from,
        address to
    ) external view returns (RouteStep[] memory) {
        return _routes[from][to];
    }

    function getAllowedExchanges() external view returns (address[] memory) {
        return _allowedExchangeSet.values();
    }

    function allowedExchangesLength() external view returns (uint256) {
        return _allowedExchangeSet.length();
    }

    function allowedExchangeAt(uint256 index) external view returns (address) {
        return _allowedExchangeSet.at(index);
    }

    function setAllowedExchange(
        address exchange,
        bool allowed
    ) external onlyGovernance {
        require(exchange != address(0), "!exchange");
        allowedExchanges[exchange] = allowed;
        if (allowed) {
            _allowedExchangeSet.add(exchange);
        } else {
            _allowedExchangeSet.remove(exchange);
            if (contextAwareExchanges[exchange]) {
                contextAwareExchanges[exchange] = false;
                emit ContextAwareExchangeSet(exchange, false);
            }
        }
        emit AllowedExchangeSet(exchange, allowed);
    }

    function setContextAwareExchange(
        address exchange,
        bool allowed
    ) external onlyGovernance {
        require(exchange != address(0), "!exchange");
        require(allowedExchanges[exchange], "!allowed");
        contextAwareExchanges[exchange] = allowed;
        emit ContextAwareExchangeSet(exchange, allowed);
    }

    function setRoute(
        address from,
        address to,
        RouteStep[] calldata route
    ) external onlyOperator {
        require(from != address(0) && to != address(0), "!token");

        delete _routes[from][to];

        uint256 length = route.length;
        if (length == 0) {
            emit RouteSet(from, to, 0);
            return;
        }

        address tokenFrom = from;

        for (uint256 i; i < length; ) {
            RouteStep calldata step = route[i];
            require(step.exchange != address(0), "!exchange");
            require(allowedExchanges[step.exchange], "!allowed");
            require(step.tokenFrom == tokenFrom, "!route");
            require(step.tokenTo != address(0), "!tokenTo");
            require(tokenFrom != step.tokenTo, "!route");
            _routes[from][to].push(step);
            tokenFrom = step.tokenTo;
            unchecked {
                ++i;
            }
        }

        require(tokenFrom == to, "!route");

        emit RouteSet(from, to, length);
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256
    ) internal override returns (uint256 amountOut) {
        if (from == to) return amountIn;

        RouteStep[] storage route = _routes[from][to];
        uint256 length = route.length;
        require(length != 0, "!route");

        address currentToken = from;
        amountOut = amountIn;

        for (uint256 i; i < length; ) {
            RouteStep storage step = route[i];
            require(allowedExchanges[step.exchange], "!allowed");
            require(step.tokenFrom == currentToken, "!route");
            ERC20(step.tokenFrom).forceApprove(step.exchange, amountOut);
            if (contextAwareExchanges[step.exchange]) {
                amountOut = IContextAwareExchange(step.exchange)
                    .exchangeWithContext(
                        currentToken,
                        step.tokenTo,
                        amountOut,
                        0,
                        msg.sender
                    );
            } else {
                amountOut = IExchange(step.exchange).exchange(
                    currentToken,
                    step.tokenTo,
                    amountOut,
                    0
                );
            }
            currentToken = step.tokenTo;
            unchecked {
                ++i;
            }
        }

        require(currentToken == to, "!route");
    }
}
