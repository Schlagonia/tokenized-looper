// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {MorphoLooper} from "../../../morpho/MorphoLooper.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {Id} from "../../../interfaces/morpho/IMorpho.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";
import {ERC4626Exchange} from "../../../periphery/ERC4626Exchange.sol";
import {LitePsmExchange} from "../../../periphery/LitePsmExchange.sol";
import {SUSDSExchange} from "../../../periphery/SUSDSExchange.sol";
import {UniswapUniversalRouterExchange} from "../../../periphery/UniswapUniversalRouterExchange.sol";

/// @notice Setup for sUSDS/USDT Morpho Looper tests
contract SetupSUSDSUSDT is Setup {
    MetaExchange public exchange;
    UniswapUniversalRouterExchange public uniExchange;
    LitePsmExchange public litePsmExchange;
    SUSDSExchange public susdsExchange;
    ERC4626Exchange public erc4626Exchange;

    Id public constant SUSDS_USDT_MARKET_ID =
        Id.wrap(
            0x3274643db77a064abd3bc851de77556a4ad2e2f502f4f0c80845fa8f909ecf0b
        );
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant LITE_PSM_WRAPPER =
        0xA188EEC8F81263234dA3622A406892F3D630f98c;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        user = makeAddr("susds-usdt-user");

        tokenAddrs["USDT"] = USDT;
        tokenAddrs["USDC"] = USDC;
        tokenAddrs["USDS"] = USDS;
        tokenAddrs["SUSDS"] = SUSDS;

        asset = ERC20(USDT);
        decimals = asset.decimals();

        maxFuzzAmount = 1_000_000e6;
        // Tiny live-fork positions can round into sub-cent rebalance hops that
        // fail the LitePSM + sUSDS route on unwind/report.
        minFuzzAmount = 500e6;

        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(SUSDS, "SUSDS");
        vm.label(USDS, "USDS");
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new MetaExchange(WETH);
        uniExchange = new UniswapUniversalRouterExchange(
            WETH,
            UNISWAP_ROUTER,
            UNISWAP_POSITION_MANAGER
        );
        litePsmExchange = new LitePsmExchange(
            USDC,
            USDS,
            LITE_PSM_WRAPPER,
            1e12
        );
        susdsExchange = new SUSDSExchange();
        erc4626Exchange = new ERC4626Exchange();

        MorphoLooper looper = new MorphoLooper(
            address(asset),
            "sUSDS/USDT Morpho Looper",
            SUSDS,
            MORPHO,
            SUSDS_USDT_MARKET_ID,
            address(exchange),
            management
        );
        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        exchange.transferGovernance(management);
        uniExchange.transferGovernance(management);
        litePsmExchange.transferGovernance(management);
        susdsExchange.transferGovernance(management);
        erc4626Exchange.transferGovernance(management);

        _strategy.setPendingManagement(management);

        vm.startPrank(management);
        _strategy.acceptManagement();
        uniExchange.setBase(USDC);
        uniExchange.setUniFees(USDT, USDC, 100);
        exchange.setAllowedExchange(address(uniExchange), true);
        exchange.setAllowedExchange(address(litePsmExchange), true);
        exchange.setAllowedExchange(address(susdsExchange), true);
        exchange.setAllowedExchange(address(erc4626Exchange), true);
        _setRoutes();

        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setEmergencyAdmin(emergencyAdmin);

        _strategy.setAllowed(user, true);
        _strategy.setMaxGasPriceToTend(type(uint256).max);

        vm.stopPrank();

        return address(_strategy);
    }

    function accrueYield(uint256 _amount) public virtual override {
        skip(1 days);
        airdrop(asset, address(strategy), (_amount * 500) / 10_000);
    }

    function _setRoutes() internal {
        MetaExchange.RouteStep[] memory forward = new MetaExchange.RouteStep[](
            3
        );
        forward[0] = MetaExchange.RouteStep({
            exchange: address(uniExchange),
            tokenTo: USDC
        });
        forward[1] = MetaExchange.RouteStep({
            exchange: address(litePsmExchange),
            tokenTo: USDS
        });
        forward[2] = MetaExchange.RouteStep({
            exchange: address(susdsExchange),
            tokenTo: SUSDS
        });
        exchange.setRoute(USDT, SUSDS, forward);

        MetaExchange.RouteStep[] memory reverse = new MetaExchange.RouteStep[](
            3
        );
        reverse[0] = MetaExchange.RouteStep({
            exchange: address(erc4626Exchange),
            tokenTo: USDS
        });
        reverse[1] = MetaExchange.RouteStep({
            exchange: address(litePsmExchange),
            tokenTo: USDC
        });
        reverse[2] = MetaExchange.RouteStep({
            exchange: address(uniExchange),
            tokenTo: USDT
        });
        exchange.setRoute(SUSDS, USDT, reverse);
    }
}
