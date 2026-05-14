// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {CurveExchange} from "../../periphery/CurveExchange.sol";

contract CurveExchangeTest is Test {
    CurveExchange internal exchange;

    address internal from = makeAddr("from");
    address internal to = makeAddr("to");
    address internal pool = makeAddr("pool");
    address internal curveRouter = makeAddr("curveRouter");

    function setUp() public {
        exchange = new CurveExchange(curveRouter);
    }

    function test_getCurveRoute_returnsConfiguredRoute() public {
        address[11] memory route;
        route[0] = from;
        route[1] = pool;
        route[2] = to;

        uint256[5][5] memory swapParams;
        swapParams[0] = [
            uint256(0),
            uint256(1),
            uint256(1),
            uint256(1),
            uint256(2)
        ];

        address[5] memory pools;
        pools[0] = pool;

        exchange.setCurveRoute(from, to, route, swapParams, pools);

        (
            address[11] memory storedRoute,
            uint256[5][5] memory storedSwapParams,
            address[5] memory storedPools
        ) = exchange.getCurveRoute(from, to);

        assertEq(storedRoute[0], from, "!from");
        assertEq(storedRoute[1], pool, "!pool");
        assertEq(storedRoute[2], to, "!to");
        assertEq(storedSwapParams[0][0], 0, "!i");
        assertEq(storedSwapParams[0][1], 1, "!j");
        assertEq(storedSwapParams[0][4], 2, "!nCoins");
        assertEq(storedPools[0], pool, "!pool");
    }
}
