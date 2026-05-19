// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {sUSDeMorphoLooper} from "../../../morpho/sUSDeMorphoLooper.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {IMorpho, Id, MarketParams} from "../../../interfaces/morpho/IMorpho.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";
import {CurveExchange} from "../../../periphery/CurveExchange.sol";
import {ERC4626Exchange} from "../../../periphery/ERC4626Exchange.sol";
import {FluidExchange} from "../../../periphery/FluidExchange.sol";

/// @notice Setup for the sUSDe/PYUSD Morpho looper tests.
contract SetupSUSDePYUSD is Setup {
    MetaExchange public exchange;
    CurveExchange public curveExchange;
    ERC4626Exchange public erc4626Exchange;
    FluidExchange public fluidExchange;

    Id public constant SUSDE_PYUSD_MARKET_ID =
        Id.wrap(
            0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
        );

    address public constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address public constant PYUSD_USDC_CURVE_POOL =
        0x383E6b4437b59fff47B619CBA855CA29342A8559;

    // Fluid DEX pools share the USDT base hub used by the existing sUSDe
    // suites — `FluidExchange` will route any (X, Y) trade through USDT.
    address public constant FLUID_USDC_USDT =
        0x667701e51B4D1Ca244F17C78F7aB8744B4C99F9B;
    address public constant FLUID_USDE_USDT =
        0xf063BD202E45d6b2843102cb4EcE339026645D4a;
    address public constant FLUID_SUSDE_USDT =
        0x1DD125C32e4B5086c63CC13B3cA02C4A2a61Fa9b;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        user = makeAddr("susde-pyusd-user");

        tokenAddrs["PYUSD"] = PYUSD;
        tokenAddrs["USDC"] = USDC;
        tokenAddrs["USDT"] = USDT;
        tokenAddrs["USDE"] = USDE;
        tokenAddrs["SUSDE"] = SUSDE;

        asset = ERC20(PYUSD);
        decimals = asset.decimals();

        // Bound to keep PYUSD/USDC and USDe/USDT pool depths comfortable.
        maxFuzzAmount = 50_000e6;
        minFuzzAmount = 100e6;

        strategy = IStrategyInterface(setUpStrategy());
        _seedSUSDePYUSDMorphoLiquidity(MORPHO_LIQUIDITY_SEED);

        factory = strategy.FACTORY();

        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(address(exchange), "exchange");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(PYUSD, "PYUSD");
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");
        vm.label(USDE, "USDE");
        vm.label(SUSDE, "SUSDE");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new MetaExchange(management);
        curveExchange = new CurveExchange(CURVE_ROUTER, management);
        erc4626Exchange = new ERC4626Exchange(management);
        fluidExchange = new FluidExchange(WETH, management);

        sUSDeMorphoLooper looper = new sUSDeMorphoLooper(
            address(asset),
            "sUSDe/PYUSD Morpho Looper",
            SUSDE,
            MORPHO,
            SUSDE_PYUSD_MARKET_ID,
            address(exchange),
            management
        );

        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        _strategy.setPendingManagement(management);

        vm.startPrank(management);
        _strategy.acceptManagement();

        // Curve PYUSD/USDC (i=0 PYUSD, j=1 USDC).
        _setCurveRoute(PYUSD, USDC, 0, 1);
        _setCurveRoute(USDC, PYUSD, 1, 0);

        // Fluid hub uses USDT; expose USDC, USDe, sUSDe legs through it.
        fluidExchange.setBase(USDT);
        fluidExchange.setFluidDex(USDC, USDT, FLUID_USDC_USDT);
        fluidExchange.setFluidDex(USDE, USDT, FLUID_USDE_USDT);
        fluidExchange.setFluidDex(SUSDE, USDT, FLUID_SUSDE_USDT);

        exchange.setAllowedExchange(address(curveExchange), true);
        exchange.setAllowedExchange(address(fluidExchange), true);
        exchange.setAllowedExchange(address(erc4626Exchange), true);
        _setRoutes();

        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setEmergencyAdmin(emergencyAdmin);
        _strategy.setAllowed(user, true);
        _strategy.setMaxGasPriceToTend(type(uint256).max);
        // Route is 3 hops on the deposit side; widen the per-trade slippage
        // budget to absorb stacked Curve+Fluid+ERC4626 spreads.
        _strategy.setSlippage(99);

        vm.stopPrank();

        return address(_strategy);
    }

    function accrueYield(uint256 _amount) public virtual override {
        skip(1 days);
        airdrop(asset, address(strategy), (_amount * 300) / 10_000);
    }

    function _setRoutes() internal {
        // Forward (PYUSD → sUSDe): 3 hops via USDC then USDe.
        MetaExchange.RouteStep[] memory forward = new MetaExchange.RouteStep[](
            3
        );
        forward[0] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenTo: USDC
        });
        forward[1] = MetaExchange.RouteStep({
            exchange: address(fluidExchange),
            tokenTo: USDE
        });
        forward[2] = MetaExchange.RouteStep({
            exchange: address(erc4626Exchange),
            tokenTo: SUSDE
        });
        exchange.setRoute(PYUSD, SUSDE, forward);

        // Reverse (sUSDe → PYUSD): rely on Fluid's sUSDe leg + Curve back to
        // PYUSD. FluidExchange handles sUSDe → USDT → USDC internally.
        MetaExchange.RouteStep[] memory unwind = new MetaExchange.RouteStep[](
            2
        );
        unwind[0] = MetaExchange.RouteStep({
            exchange: address(fluidExchange),
            tokenTo: USDC
        });
        unwind[1] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenTo: PYUSD
        });
        exchange.setRoute(SUSDE, PYUSD, unwind);

        // Cooldown post-claim: USDe → PYUSD via Fluid + Curve.
        MetaExchange.RouteStep[]
            memory underlyingToAsset = new MetaExchange.RouteStep[](2);
        underlyingToAsset[0] = MetaExchange.RouteStep({
            exchange: address(fluidExchange),
            tokenTo: USDC
        });
        underlyingToAsset[1] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenTo: PYUSD
        });
        exchange.setRoute(USDE, PYUSD, underlyingToAsset);
    }

    function _setCurveRoute(
        address from,
        address to,
        uint256 i,
        uint256 j
    ) internal {
        address[11] memory route;
        route[0] = from;
        route[1] = PYUSD_USDC_CURVE_POOL;
        route[2] = to;

        uint256[5][5] memory swapParams;
        swapParams[0] = [i, j, 1, 1, 2];

        address[5] memory pools;

        curveExchange.setCurveRoute(from, to, route, swapParams, pools);
    }

    function _seedSUSDePYUSDMorphoLiquidity(uint256 amount) internal {
        MarketParams memory params = IMorpho(MORPHO).idToMarketParams(
            SUSDE_PYUSD_MARKET_ID
        );
        deal(address(asset), address(this), amount);
        asset.approve(MORPHO, amount);
        IMorpho(MORPHO).supply(params, amount, 0, address(this), "");
    }
}
