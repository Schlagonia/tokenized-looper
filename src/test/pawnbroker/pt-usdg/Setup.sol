// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {PawnBrokerLooper} from "../../../pawnbroker/PawnBrokerLooper.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {IPawnBroker} from "pawn-broker/interfaces/IPawnBroker.sol";
import {PawnBrokerFactory} from "pawn-broker/PawnBrokerFactory.sol";
import {MockMorphoOracle} from "pawn-broker/test/mocks/MockMorphoOracle.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";
import {CurveExchange} from "../../../periphery/CurveExchange.sol";
import {PendleExchange} from "../../../periphery/PendleExchange.sol";

/// @notice Setup for a USDC / PT-USDG Pendle pawn broker looper.
contract SetupPawnBrokerPTUSDG is Setup {
    PawnBrokerLooper public looper;
    MetaExchange public exchange;
    IPawnBroker public pawnBroker;
    PawnBrokerFactory public pawnBrokerFactory;
    MockMorphoOracle public oracle;
    CurveExchange public curveExchange;
    PendleExchange public pendleExchange;

    address public lender = makeAddr("pawn-broker-pt-lender");
    address public user2 = makeAddr("pawn-broker-pt-second-user");

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDG = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D;
    address public constant PT_USDG_28_MAY_2026 =
        0x9db38D74a0D29380899aD354121DfB521aDb0548;
    address public constant PENDLE_MARKET =
        0xC5b32dba5f29F8395fb9591E1a15f23A75214F33;
    address public constant CURVE_USDG_USDC_POOL =
        0xc061caa073f3d95F80f8e5428d32D2d76F5e1622;

    uint256 public constant PAWN_BROKER_LIQUIDITY = 5_000_000e6;
    uint256 public constant MORPHO_FLASHLOAN_LIQUIDITY = 5_000_000e6;
    uint256 public constant PAWN_BROKER_LLTV = 915e15;
    uint256 public constant PAWN_BROKER_RATE = 400;
    uint256 public constant PAWN_BROKER_CALL_DURATION = 7 days;
    uint256 public constant PT_ORACLE_PRICE = 995e33; // 0.995 USDG per PT

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        tokenAddrs["USDC"] = USDC;
        tokenAddrs["PT_USDG_28_MAY_2026"] = PT_USDG_28_MAY_2026;

        asset = ERC20(USDC);
        decimals = asset.decimals();

        // Keep fork trades small enough that Pendle does not start throwing furniture.
        maxFuzzAmount = 10_000e6;
        minFuzzAmount = 100e6;

        strategy = IStrategyInterface(setUpStrategy());
        factory = strategy.FACTORY();

        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(address(strategy), "strategy");
        vm.label(address(exchange), "exchange");
        vm.label(address(pawnBroker), "pawnBroker");
        vm.label(address(pawnBrokerFactory), "pawnBrokerFactory");
        vm.label(address(oracle), "pawnBrokerOracle");
        vm.label(management, "management");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(lender, "pawnBrokerLender");
        vm.label(user2, "pawnBrokerSecondUser");
        vm.label(PT_USDG_28_MAY_2026, "ptUSDGMay2026");
        vm.label(PENDLE_MARKET, "pendleMarket");
    }

    function setUpStrategy() public virtual override returns (address) {
        pawnBrokerFactory = new PawnBrokerFactory(
            management,
            performanceFeeRecipient,
            keeper,
            emergencyAdmin
        );

        oracle = new MockMorphoOracle();
        oracle.setPrice(PT_ORACLE_PRICE);

        exchange = new MetaExchange(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        curveExchange = new CurveExchange(CURVE_ROUTER);
        pendleExchange = new PendleExchange(PENDLE_ROUTER);

        address predictedLooper = vm.computeCreateAddress(
            address(this),
            vm.getNonce(address(this))
        );

        pawnBroker = IPawnBroker(
            pawnBrokerFactory.newPawnBroker(
                address(asset),
                "USDC PT Pawn Broker Market",
                predictedLooper,
                PT_USDG_28_MAY_2026,
                address(oracle),
                PAWN_BROKER_LLTV,
                PAWN_BROKER_RATE,
                PAWN_BROKER_CALL_DURATION
            )
        );

        vm.prank(management);
        pawnBroker.acceptManagement();

        looper = new PawnBrokerLooper(
            address(asset),
            "USDC PT Pawn Broker Looper",
            PT_USDG_28_MAY_2026,
            MORPHO,
            address(pawnBroker),
            address(exchange),
            management
        );

        exchange.transferGovernance(management);
        curveExchange.transferGovernance(management);
        pendleExchange.transferGovernance(management);

        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        _strategy.setPendingManagement(management);

        vm.startPrank(management);
        _strategy.acceptManagement();
        pendleExchange.setPendleMarket(PT_USDG_28_MAY_2026, PENDLE_MARKET);
        pendleExchange.setGuessMaxMultiplier(2);
        _setCurveRoute(address(asset), USDG, 1, 0);
        _setCurveRoute(USDG, address(asset), 0, 1);
        exchange.setAllowedExchange(address(curveExchange), true);
        exchange.setAllowedExchange(address(pendleExchange), true);
        _setRoutes();
        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setEmergencyAdmin(emergencyAdmin);
        _strategy.setAllowed(user, true);
        _strategy.setAllowed(user2, true);
        _strategy.setMaxGasPriceToTend(type(uint256).max);
        _strategy.setProfitMaxUnlockTime(0);
        _strategy.setSlippage(99);
        vm.stopPrank();

        _seedPawnBrokerLiquidity(PAWN_BROKER_LIQUIDITY);
        _seedMorphoFlashloanLiquidity(MORPHO_FLASHLOAN_LIQUIDITY);

        return address(_strategy);
    }

    function accrueYield(uint256 _amount) public virtual override {
        // PT paths hate big time warps. Airdrop profits and keep the clock sober.
        airdrop(asset, address(strategy), _amount / 30);
    }

    function _seedPawnBrokerLiquidity(uint256 _amount) internal {
        vm.prank(management);
        pawnBroker.setAllowed(lender, true);

        airdrop(asset, lender, _amount);

        vm.startPrank(lender);
        asset.approve(address(pawnBroker), _amount);
        pawnBroker.deposit(_amount, lender);
        vm.stopPrank();
    }

    function _seedMorphoFlashloanLiquidity(uint256 _amount) internal {
        uint256 existingBalance = asset.balanceOf(MORPHO);
        deal(address(asset), MORPHO, existingBalance + _amount);
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

        curveExchange.setCurveRoute(_from, _to, route, swapParams, pools);
    }

    function _setRoutes() internal {
        MetaExchange.RouteStep[]
            memory assetToPt = new MetaExchange.RouteStep[](2);
        assetToPt[0] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenTo: USDG
        });
        assetToPt[1] = MetaExchange.RouteStep({
            exchange: address(pendleExchange),
            tokenTo: PT_USDG_28_MAY_2026
        });
        exchange.setRoute(address(asset), PT_USDG_28_MAY_2026, assetToPt);

        MetaExchange.RouteStep[]
            memory ptToAsset = new MetaExchange.RouteStep[](2);
        ptToAsset[0] = MetaExchange.RouteStep({
            exchange: address(pendleExchange),
            tokenTo: USDG
        });
        ptToAsset[1] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenTo: address(asset)
        });
        exchange.setRoute(PT_USDG_28_MAY_2026, address(asset), ptToAsset);
    }
}
