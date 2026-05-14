// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {sUSDeAaveLooper} from "../../../aave/sUSDeAaveLooper.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";
import {ERC4626Exchange} from "../../../periphery/ERC4626Exchange.sol";
import {FluidExchange} from "../../../periphery/FluidExchange.sol";

/// @notice Setup for sUSDe/USDC Aave V3 looper tests.
contract SetupAavesUSDeUSDC is Setup {
    MetaExchange public exchange;
    FluidExchange public fluidExchange;
    ERC4626Exchange public erc4626Exchange;

    // Aave V3 core (Ethereum mainnet)
    address public constant AAVE_ADDRESSES_PROVIDER =
        0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant MORPHO_FLASHLOAN_PROVIDER =
        0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // Token config
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Fluid DEX config
    address public constant FLUID_USDC_USDT =
        0x667701e51B4D1Ca244F17C78F7aB8744B4C99F9B;
    address public constant FLUID_USDE_USDT =
        0xf063BD202E45d6b2843102cb4EcE339026645D4a;
    address public constant FLUID_SUSDE_USDT =
        0x1DD125C32e4B5086c63CC13B3cA02C4A2a61Fa9b;

    // Aave sUSDe stablecoin liquid e-mode.
    uint8 public constant EMODE_CATEGORY_ID = 2;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        tokenAddrs["USDC"] = USDC;
        tokenAddrs["USDT"] = USDT;
        tokenAddrs["USDE"] = USDE;
        tokenAddrs["SUSDE"] = SUSDE;

        asset = ERC20(USDC);
        decimals = asset.decimals();

        // Keep fork tests in a range that won't bully thinner side liquidity.
        maxFuzzAmount = 500_000e6;
        minFuzzAmount = 100e6;

        strategy = IStrategyInterface(setUpStrategy());
        factory = strategy.FACTORY();

        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(USDT, "USDT");
        vm.label(USDE, "USDE");
        vm.label(SUSDE, "SUSDE");
        vm.label(AAVE_ADDRESSES_PROVIDER, "AAVE_ADDRESSES_PROVIDER");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new MetaExchange(WETH);
        fluidExchange = new FluidExchange(WETH);
        erc4626Exchange = new ERC4626Exchange();

        sUSDeAaveLooper looper = new sUSDeAaveLooper(
            address(asset),
            "sUSDe/USDC Aave Looper",
            SUSDE,
            AAVE_ADDRESSES_PROVIDER,
            MORPHO_FLASHLOAN_PROVIDER,
            EMODE_CATEGORY_ID,
            address(exchange),
            management
        );

        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        exchange.transferGovernance(management);
        fluidExchange.transferGovernance(management);
        erc4626Exchange.transferGovernance(management);
        _strategy.setPendingManagement(management);

        vm.startPrank(management);
        _strategy.acceptManagement();

        fluidExchange.setBase(USDT);
        fluidExchange.setFluidDex(USDC, USDT, FLUID_USDC_USDT);
        fluidExchange.setFluidDex(USDE, USDT, FLUID_USDE_USDT);
        fluidExchange.setFluidDex(SUSDE, USDT, FLUID_SUSDE_USDT);
        exchange.setAllowedExchange(address(fluidExchange), true);
        exchange.setAllowedExchange(address(erc4626Exchange), true);
        _setRoutes();

        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setEmergencyAdmin(emergencyAdmin);

        // Allow first reports without tripping health check.
        _strategy.setAllowed(user, true);

        // Set high gas price tolerance for testing.
        _strategy.setMaxGasPriceToTend(type(uint256).max);

        vm.stopPrank();

        return address(_strategy);
    }

    function accrueYield(uint256 _amount) public virtual override {
        skip(1 days);
        airdrop(asset, address(strategy), (_amount * 300) / 10_000);
    }

    function _setRoutes() internal {
        MetaExchange.RouteStep[] memory forward = new MetaExchange.RouteStep[](
            2
        );
        forward[0] = MetaExchange.RouteStep({
            exchange: address(fluidExchange),
            tokenTo: USDE
        });
        forward[1] = MetaExchange.RouteStep({
            exchange: address(erc4626Exchange),
            tokenTo: SUSDE
        });
        exchange.setRoute(USDC, SUSDE, forward);

        MetaExchange.RouteStep[] memory unwind = new MetaExchange.RouteStep[](
            1
        );
        unwind[0] = MetaExchange.RouteStep({
            exchange: address(fluidExchange),
            tokenTo: USDC
        });
        exchange.setRoute(SUSDE, USDC, unwind);

        MetaExchange.RouteStep[]
            memory underlyingToAsset = new MetaExchange.RouteStep[](1);
        underlyingToAsset[0] = MetaExchange.RouteStep({
            exchange: address(fluidExchange),
            tokenTo: USDC
        });
        exchange.setRoute(USDE, USDC, underlyingToAsset);
    }
}
