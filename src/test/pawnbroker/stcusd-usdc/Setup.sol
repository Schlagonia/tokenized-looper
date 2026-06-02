// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {PawnBrokerLooper} from "../../../pawnbroker/PawnBrokerLooper.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {IPawnBroker} from "pawn-broker/interfaces/IPawnBroker.sol";
import {IMorphoOracle} from "pawn-broker/interfaces/IMorphoOracle.sol";
import {PawnBrokerFactory} from "pawn-broker/PawnBrokerFactory.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";
import {CapUSDExchange} from "../../../periphery/CapUSDExchange.sol";
import {ERC4626Exchange} from "../../../periphery/ERC4626Exchange.sol";

/// @notice Setup for a USDC / stcUSD pawn broker looper.
contract SetupPawnBrokerSTCUSD is Setup {
    PawnBrokerLooper public looper;
    MetaExchange public exchange;
    IPawnBroker public pawnBroker;
    PawnBrokerFactory public pawnBrokerFactory;
    IMorphoOracle public oracle;
    CapUSDExchange public capExchange;
    ERC4626Exchange public erc4626Exchange;

    address public lender = makeAddr("pawn-broker-stcusd-lender");
    address public user2 = makeAddr("pawn-broker-stcusd-second-user");

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant CUSD = 0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC;
    address public constant STCUSD = 0x88887bE419578051FF9F4eb6C858A951921D8888;
    address public constant STCUSD_ORACLE =
        0x8E3386B2f6084eB1B0988070c3d826995BD175c0;

    uint256 public constant PAWN_BROKER_LIQUIDITY = 5_000_000e6;
    uint256 public constant MORPHO_FLASHLOAN_LIQUIDITY = 5_000_000e6;
    uint256 public constant PAWN_BROKER_LLTV = 915e15;
    uint256 public constant PAWN_BROKER_RATE = 300;
    uint256 public constant PAWN_BROKER_CALL_DURATION = 7 days;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        tokenAddrs["USDC"] = USDC;
        tokenAddrs["STCUSD"] = STCUSD;

        asset = ERC20(USDC);
        decimals = asset.decimals();

        // Keep fork trades small enough for live mint/burn liquidity.
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
        vm.label(CUSD, "cUSD");
        vm.label(STCUSD, "stcUSD");
    }

    function setUpStrategy() public virtual override returns (address) {
        pawnBrokerFactory = new PawnBrokerFactory(
            management,
            performanceFeeRecipient,
            keeper,
            emergencyAdmin
        );

        oracle = IMorphoOracle(STCUSD_ORACLE);

        exchange = new MetaExchange(management);
        capExchange = new CapUSDExchange(address(asset), CUSD, management);
        erc4626Exchange = new ERC4626Exchange(management);

        address predictedLooper = vm.computeCreateAddress(
            address(this),
            vm.getNonce(address(this))
        );

        pawnBroker = IPawnBroker(
            pawnBrokerFactory.newPawnBroker(
                address(asset),
                "USDC stcUSD Pawn Broker Market",
                predictedLooper,
                STCUSD,
                STCUSD_ORACLE,
                PAWN_BROKER_LLTV,
                PAWN_BROKER_RATE,
                PAWN_BROKER_CALL_DURATION
            )
        );

        vm.prank(management);
        pawnBroker.acceptManagement();

        looper = new PawnBrokerLooper(
            address(asset),
            "USDC stcUSD Pawn Broker Looper",
            STCUSD,
            MORPHO,
            address(pawnBroker),
            address(exchange),
            management
        );

        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        _strategy.setPendingManagement(management);

        vm.startPrank(management);
        _strategy.acceptManagement();
        exchange.setAllowedExchange(address(capExchange), true);
        exchange.setAllowedExchange(address(erc4626Exchange), true);
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
        airdrop(asset, address(strategy), _amount / 100);
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

    function _setRoutes() internal {
        MetaExchange.RouteStep[]
            memory assetToStcUsd = new MetaExchange.RouteStep[](2);
        assetToStcUsd[0] = MetaExchange.RouteStep({
            exchange: address(capExchange),
            tokenFrom: address(asset),
            tokenTo: CUSD
        });
        assetToStcUsd[1] = MetaExchange.RouteStep({
            exchange: address(erc4626Exchange),
            tokenFrom: CUSD,
            tokenTo: STCUSD
        });
        exchange.setRoute(address(asset), STCUSD, assetToStcUsd);

        MetaExchange.RouteStep[]
            memory stcUsdToAsset = new MetaExchange.RouteStep[](2);
        stcUsdToAsset[0] = MetaExchange.RouteStep({
            exchange: address(erc4626Exchange),
            tokenFrom: STCUSD,
            tokenTo: CUSD
        });
        stcUsdToAsset[1] = MetaExchange.RouteStep({
            exchange: address(capExchange),
            tokenFrom: CUSD,
            tokenTo: address(asset)
        });
        exchange.setRoute(STCUSD, address(asset), stcUsdToAsset);
    }
}
