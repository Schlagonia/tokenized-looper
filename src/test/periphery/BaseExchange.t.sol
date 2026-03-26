// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IExchange} from "../../interfaces/IExchange.sol";
import {BaseExchange} from "../../periphery/BaseExchange.sol";

contract BaseExchangeTestToken is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockStrategyForBaseExchange {
    address public management;
    address public GOVERNANCE;
    IExchange public exchange;

    constructor(address _management, address _governance) {
        management = _management;
        GOVERNANCE = _governance;
    }

    function setExchange(address _exchange) external {
        exchange = IExchange(_exchange);
    }

    function approveToken(
        address token,
        address spender,
        uint256 amount
    ) external {
        ERC20(token).approve(spender, amount);
    }

    function swap(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) external returns (uint256 amountOut) {
        return exchange.exchange(from, to, amountIn, amountOutMin);
    }

    function swapWithData(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes calldata data
    ) external returns (uint256 amountOut) {
        return exchange.exchange(from, to, amountIn, amountOutMin, data);
    }
}

contract MockBaseExchange is BaseExchange {
    bytes public lastData;

    function _exchange(
        address,
        address,
        uint256 amountIn,
        uint256
    ) internal pure override returns (uint256 amountOut) {
        return amountIn;
    }

    function _exchange(
        address,
        address,
        uint256 amountIn,
        uint256,
        bytes memory data
    ) internal override returns (uint256 amountOut) {
        lastData = data;
        return amountIn + abi.decode(data, (uint256));
    }
}

contract BaseExchangeTest is Test {
    BaseExchangeTestToken internal asset;
    BaseExchangeTestToken internal collateral;
    MockBaseExchange internal exchange;
    MockStrategyForBaseExchange internal strategy;

    address internal governance = makeAddr("governance");

    function setUp() public {
        asset = new BaseExchangeTestToken("Asset", "AST");
        collateral = new BaseExchangeTestToken("Collateral", "COL");
        exchange = new MockBaseExchange();
        strategy = new MockStrategyForBaseExchange(address(this), governance);

        exchange.setStrategy(address(strategy));
        strategy.setExchange(address(exchange));

        strategy.approveToken(
            address(asset),
            address(exchange),
            type(uint256).max
        );

        asset.mint(address(strategy), 100e18);
        collateral.mint(address(exchange), 1_000e18);
    }

    function test_exchange_withoutData_usesLegacyPath() public {
        uint256 amountOut = strategy.swap(
            address(asset),
            address(collateral),
            10e18,
            0
        );

        assertEq(amountOut, 10e18, "!amountOut");
        assertEq(collateral.balanceOf(address(strategy)), 10e18, "!balance");
    }

    function test_exchange_withData_usesExtendedPath() public {
        uint256 amountOut = strategy.swapWithData(
            address(asset),
            address(collateral),
            10e18,
            0,
            abi.encode(5e18)
        );

        assertEq(amountOut, 15e18, "!amountOut");
        assertEq(collateral.balanceOf(address(strategy)), 15e18, "!balance");
        assertEq(exchange.lastData(), abi.encode(5e18), "!data");
    }
}
