// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {OriginERC4626CurveExchange} from "../../periphery/OriginERC4626CurveExchange.sol";

contract ERC4626CurveExchangeForkTest is Test {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant OUSD = 0x2A8e1E676Ec238d8A992307B495b45B3fEAa5e86;
    address internal constant WOUSD =
        0xD2af830E8CBdFed6CC11Bab697bB25496ed6FA62;
    address internal constant CURVE_OUSD_USDC_POOL =
        0x6d18E1a7faeB1F0467A77C0d293872ab685426dc;

    OriginERC4626CurveExchange internal exchange;
    ERC20 internal usdc;
    ERC20 internal ousd;
    ERC20 internal wousd;

    function management() external view returns (address) {
        return address(this);
    }

    function GOVERNANCE() external view returns (address) {
        return address(this);
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        usdc = ERC20(USDC);
        ousd = ERC20(OUSD);
        wousd = ERC20(WOUSD);

        exchange = new OriginERC4626CurveExchange(USDC, WOUSD);
        exchange.setStrategy(address(this));

        exchange.setMint(true);
        exchange.setDeposit(true);
        exchange.setRedeem(true);
        _setCurveRoute(OUSD, USDC, 0, 1);
    }

    function test_constructorPinsExpectedTokens() public view {
        assertEq(exchange.ASSET(), USDC, "!asset");
        assertEq(exchange.UNDERLYING(), OUSD, "!underlying");
        assertEq(exchange.COLLATERAL(), WOUSD, "!collateral");
    }

    function test_directMintDoesNotNeedUsdcToOusdCurveRoute() public {
        uint256 amountIn = 1_000e6;

        deal(USDC, address(this), amountIn);
        usdc.approve(address(exchange), amountIn);

        uint256 ousdBefore = ousd.balanceOf(address(exchange));
        uint256 sharesOut = exchange.exchange(USDC, WOUSD, amountIn, 0);

        assertGt(sharesOut, 0, "!sharesOut");
        assertEq(
            ousd.balanceOf(address(exchange)),
            ousdBefore,
            "!no loose ousd"
        );
    }

    function test_exchange_roundTripsUsdcAndWOusd() public {
        uint256 amountIn = 1_000e6;

        deal(USDC, address(this), amountIn);
        usdc.approve(address(exchange), amountIn);

        uint256 sharesOut = exchange.exchange(USDC, WOUSD, amountIn, 0);
        assertGt(sharesOut, 0, "!sharesOut");
        assertEq(usdc.balanceOf(address(this)), 0, "!usdc spent");

        wousd.approve(address(exchange), sharesOut);
        uint256 assetOut = exchange.exchange(WOUSD, USDC, sharesOut, 0);

        assertGt(assetOut, 0, "!assetOut");
        assertEq(wousd.balanceOf(address(this)), 0, "!wousd spent");
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
        route[1] = CURVE_OUSD_USDC_POOL;
        route[2] = _to;

        uint256[5][5] memory swapParams;
        swapParams[0] = [_i, _j, 1, 1, 2];

        address[5] memory pools;

        exchange.setCurveRoute(_from, _to, route, swapParams, pools);
    }
}
