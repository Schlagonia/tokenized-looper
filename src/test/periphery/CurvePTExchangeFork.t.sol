// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CurvePTExchange} from "../../periphery/CurvePTExchange.sol";

contract CurvePTExchangeForkTest is Test {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDG = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D;
    address internal constant PT_USDG_28_MAY_2026 =
        0x9db38D74a0D29380899aD354121DfB521aDb0548;
    address internal constant PENDLE_MARKET =
        0xC5b32dba5f29F8395fb9591E1a15f23A75214F33;
    address internal constant CURVE_USDG_USDC_POOL =
        0xc061caa073f3d95F80f8e5428d32D2d76F5e1622;

    CurvePTExchange internal exchange;
    ERC20 internal usdc;
    ERC20 internal usdg;
    ERC20 internal pt;

    function management() external view returns (address) {
        return address(this);
    }

    function GOVERNANCE() external view returns (address) {
        return address(this);
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        usdc = ERC20(USDC);
        usdg = ERC20(USDG);
        pt = ERC20(PT_USDG_28_MAY_2026);

        exchange = new CurvePTExchange(
            USDC,
            PT_USDG_28_MAY_2026,
            PENDLE_MARKET,
            USDG
        );
        exchange.setStrategy(address(this));
        _setCurveRoute(USDC, USDG, 1, 0);
        _setCurveRoute(USDG, USDC, 0, 1);
    }

    function test_constructorPinsExpectedMarket() public view {
        assertEq(exchange.ASSET(), USDC, "!asset");
        assertEq(exchange.COLLATERAL(), PT_USDG_28_MAY_2026, "!pt");
        assertEq(exchange.PENDLE_MARKET(), PENDLE_MARKET, "!market");
        assertEq(exchange.PENDLE_TOKEN(), USDG, "!pendle token");
    }

    function test_exchange_roundTripsUsdcAndPt() public {
        uint256 amountIn = 1_000e6;

        deal(USDC, address(this), amountIn);
        usdc.approve(address(exchange), amountIn);

        uint256 ptOut = exchange.exchange(
            USDC,
            PT_USDG_28_MAY_2026,
            amountIn,
            0
        );
        assertGt(ptOut, 0, "!ptOut");
        assertEq(usdc.balanceOf(address(this)), 0, "!usdc spent");

        pt.approve(address(exchange), ptOut);
        uint256 assetOut = exchange.exchange(
            PT_USDG_28_MAY_2026,
            USDC,
            ptOut,
            0
        );

        assertGt(assetOut, 0, "!assetOut");
        assertEq(pt.balanceOf(address(this)), 0, "!pt spent");
        assertGt(usdc.balanceOf(address(this)), 0, "!final usdc");
    }

    function _setCurveRoute(
        address _from,
        address _to,
        uint256 _i,
        uint256 _j
    ) internal {
        address[11] memory route;
        route[0] = _from;
        route[1] = CURVE_USDG_USDC_POOL;
        route[2] = _to;

        uint256[5][5] memory swapParams;
        swapParams[0] = [_i, _j, 1, 1, 2];

        address[5] memory pools;

        exchange.setCurveRoute(_from, _to, route, swapParams, pools);
    }
}
