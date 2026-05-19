// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {CurveExchange} from "../../periphery/CurveExchange.sol";
import {PendleExchange} from "../../periphery/PendleExchange.sol";
import {UniswapUniversalRouterExchange} from "../../periphery/UniswapUniversalRouterExchange.sol";

contract ExchangeAdminTest is Test {
    address internal weth = makeAddr("weth");
    address internal curveRouter = makeAddr("curveRouter");
    address internal pendleRouter = makeAddr("pendleRouter");
    address internal uniRouter = makeAddr("uniRouter");
    address internal positionManager = makeAddr("positionManager");

    function test_routerAddresses_areSetByConstructors() public {
        CurveExchange curve = new CurveExchange(curveRouter, address(this));
        PendleExchange pendle = new PendleExchange(pendleRouter, address(this));
        UniswapUniversalRouterExchange uni = new UniswapUniversalRouterExchange(
            weth,
            uniRouter,
            positionManager,
            address(this)
        );

        assertEq(curve.curveRouter(), curveRouter, "!curve router");
        assertEq(pendle.pendleRouter(), pendleRouter, "!pendle router");
        assertEq(uni.router(), uniRouter, "!uni router");
        assertEq(uni.positionManager(), positionManager, "!position manager");
    }

    function test_routerConstructors_revertOnZeroAddress() public {
        vm.expectRevert("!router");
        new CurveExchange(address(0), address(this));

        vm.expectRevert("!router");
        new PendleExchange(address(0), address(this));

        vm.expectRevert("!router");
        new UniswapUniversalRouterExchange(
            weth,
            address(0),
            positionManager,
            address(this)
        );

        vm.expectRevert("!positionManager");
        new UniswapUniversalRouterExchange(
            weth,
            uniRouter,
            address(0),
            address(this)
        );
    }
}
