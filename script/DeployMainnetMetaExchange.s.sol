// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolPermissionManager} from "../src/interfaces/syrup/IPoolPermissionManager.sol";
import {ISyrupRouter} from "../src/interfaces/syrup/ISyrupRouter.sol";
import {CurveExchange} from "../src/periphery/CurveExchange.sol";
import {ERC4626Exchange} from "../src/periphery/ERC4626Exchange.sol";
import {FluidExchange} from "../src/periphery/FluidExchange.sol";
import {GovernanceMulticall} from "../src/periphery/GovernanceMulticall.sol";
import {LitePsmExchange} from "../src/periphery/LitePsmExchange.sol";
import {MetaExchange} from "../src/periphery/MetaExchange.sol";
import {OriginMintExchange} from "../src/periphery/OriginMintExchange.sol";
import {PendleExchange} from "../src/periphery/PendleExchange.sol";
import {SUSDSExchange} from "../src/periphery/SUSDSExchange.sol";
import {SyrupDepositExchange} from "../src/periphery/SyrupDepositExchange.sol";
import {UniswapUniversalRouterExchange} from "../src/periphery/UniswapUniversalRouterExchange.sol";

interface ICreateXDeployer {
    function deployCreate2(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
}

contract DeployMainnetMetaExchange is Script {
    struct Deployment {
        address metaExchange;
        address uniswapUniversal;
        address curve;
        address fluid;
        address pendle;
        address erc4626;
        address litePsm;
        address syrupDeposit;
        address susds;
        address originMint;
    }

    bytes32 internal constant MAPLE_DEPOSIT_PERMISSION = bytes32("P:deposit");
    bytes32 internal constant SYRUP_DEPOSIT_DATA = bytes32("Yearn");

    address internal constant DEFAULT_GOVERNANCE = 0x1b5f15DCb82d25f91c65b53CEe151E8b9fBdD271;
    address internal constant EXCHANGE_OPERATOR = 0xb7E062f8b7da0d26e202A859B008F59D7eAd6526;
    address internal constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant CURVE_ROUTER = 0xF0d4c12A5768D806021F80a262B4d39d26C58b8D;
    address internal constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address internal constant UNISWAP_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant UNISWAP_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDTB = 0xC139190F447e929f090Edeb554D95AbB8b18aC1C;
    address internal constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address internal constant OUSD = 0x2A8e1E676Ec238d8A992307B495b45B3fEAa5e86;
    address internal constant WOUSD = 0xD2af830E8CBdFed6CC11Bab697bB25496ed6FA62;
    address internal constant USDG = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D;

    address internal constant SYRUP_USDC = 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;
    address internal constant SYRUP_USDC_ROUTER = 0x134cCaaA4F1e4552eC8aEcb9E4A2360dDcF8df76;
    bytes32 internal constant SYRUP_USDC_USDC_V4_POOL_ID =
        0xcdb422a853a4fa2deb364317db92ad76d1cb7a8e1b82a32219bcb41720a90228;

    address internal constant SYRUP_USDT = 0x356B8d89c1e1239Cbbb9dE4815c39A1474d5BA7D;
    address internal constant SYRUP_USDT_ROUTER = 0xF007476Bb27430795138C511F18F821e8D1e5Ee2;
    bytes32 internal constant DEFAULT_SYRUP_USDT_V4_POOL_ID =
        0xd861038a98942312d1495dd1313fb66c7e7de48f549a15edf3a45decf7338e1d;

    address internal constant PYUSD_USDC_CURVE_POOL = 0x383E6b4437b59fff47B619CBA855CA29342A8559;
    address internal constant CURVE_USDC_USDTB_POOL = 0xC2921134073151490193AC7369313c8e0b08e1E7;
    address internal constant CURVE_OUSD_USDC_POOL = 0x6d18E1a7faeB1F0467A77C0d293872ab685426dc;
    address internal constant CURVE_USDG_USDC_POOL = 0xc061caa073f3d95F80f8e5428d32D2d76F5e1622;

    address internal constant LITE_PSM_WRAPPER = 0xA188EEC8F81263234dA3622A406892F3D630f98c;

    address internal constant FLUID_USDC_USDT = 0x667701e51B4D1Ca244F17C78F7aB8744B4C99F9B;
    address internal constant FLUID_USDE_USDT = 0xf063BD202E45d6b2843102cb4EcE339026645D4a;
    address internal constant FLUID_SUSDE_USDT = 0x1DD125C32e4B5086c63CC13B3cA02C4A2a61Fa9b;
    address internal constant FLUID_USDE_USDTB = 0xB0960263E39C70C9B6e9EA2A382B18095264A364;

    address internal constant PT_USDG_24_SEP_2026 = 0xc1906aeCf868749a2DeE203F59b904c0cf212140;
    address internal constant PENDLE_USDG_MARKET = 0xF80b67a32DF07960C731794769309E3D30E9717F;

    address public governance = DEFAULT_GOVERNANCE;
    address public exchangeGovernance = governance;
    GovernanceMulticall public deploymentMulticall;
    bool public useDeploymentMulticall = true;
    bool public useSyrupUsdtMint = false;
    bytes32 public syrupUsdtV4PoolId = DEFAULT_SYRUP_USDT_V4_POOL_ID;
    uint24 public syrupUsdtUniFee = 0;

    function run() external returns (Deployment memory d) {
        require(block.chainid == 1, "!mainnet");

        exchangeGovernance = vm.envOr("EXCHANGE_GOVERNANCE", governance);

        vm.startBroadcast();
        if (useDeploymentMulticall) {
            deploymentMulticall = new GovernanceMulticall(governance);
            exchangeGovernance = address(deploymentMulticall);
        }

        d = _deploy();
        if (useDeploymentMulticall) {
            MetaExchange(payable(d.metaExchange)).transferGovernance(address(deploymentMulticall));
            _configureThroughMulticall(d);
        } else {
            _configureVenues(d);
            _allowVenues(d);
            _configureRoutes(d);
            _setOperators(d);
        }

        _validate(d);
        vm.stopBroadcast();

        _logDeployment(d);
    }

    function _deploy() internal returns (Deployment memory d) {
        d.metaExchange = _deployMetaExchange();
        d.uniswapUniversal = address(
            new UniswapUniversalRouterExchange(WETH, UNISWAP_ROUTER, UNISWAP_POSITION_MANAGER, exchangeGovernance)
        );
        d.curve = address(new CurveExchange(CURVE_ROUTER, exchangeGovernance));
        d.fluid = address(new FluidExchange(WETH, exchangeGovernance));
        d.pendle = address(new PendleExchange(PENDLE_ROUTER, exchangeGovernance));
        d.erc4626 = address(new ERC4626Exchange(exchangeGovernance));
        d.litePsm = address(new LitePsmExchange(USDC, USDS, LITE_PSM_WRAPPER, 1e12, exchangeGovernance));
        d.syrupDeposit = address(new SyrupDepositExchange(exchangeGovernance));
        d.susds = address(new SUSDSExchange(exchangeGovernance));
        d.originMint = address(new OriginMintExchange(exchangeGovernance));
    }

    function _deployMetaExchange() internal returns (address) {
        bytes memory initCode = abi.encodePacked(type(MetaExchange).creationCode, abi.encode(governance));

        return ICreateXDeployer(CREATE_X)
            .deployCreate2(0x1b5f15dcb82d25f91c65b53cee151e8b9fbdd271000000000000000000098677, initCode);
    }

    function _configureVenues(Deployment memory d) internal {
        UniswapUniversalRouterExchange uni = UniswapUniversalRouterExchange(payable(d.uniswapUniversal));
        CurveExchange curve = CurveExchange(d.curve);
        FluidExchange fluid = FluidExchange(payable(d.fluid));
        PendleExchange pendle = PendleExchange(d.pendle);
        SyrupDepositExchange syrup = SyrupDepositExchange(d.syrupDeposit);

        uni.setBase(USDC);
        uni.setUniFees(USDT, USDC, 100);
        uni.setV4Pool(USDC, SYRUP_USDC, SYRUP_USDC_USDC_V4_POOL_ID);
        uni.setV4Pool(USDT, SYRUP_USDT, syrupUsdtV4PoolId);
        if (syrupUsdtUniFee != 0) {
            uni.setUniFees(USDT, SYRUP_USDT, syrupUsdtUniFee);
        }

        _setCurveRoute(curve, PYUSD, USDC, PYUSD_USDC_CURVE_POOL, 0, 1);
        _setCurveRoute(curve, USDC, PYUSD, PYUSD_USDC_CURVE_POOL, 1, 0);
        _setCurveRoute(curve, USDC, USDTB, CURVE_USDC_USDTB_POOL, 0, 1);
        _setCurveRoute(curve, USDTB, USDC, CURVE_USDC_USDTB_POOL, 1, 0);
        _setCurveRoute(curve, OUSD, USDC, CURVE_OUSD_USDC_POOL, 0, 1);
        _setCurveRoute(curve, USDC, USDG, CURVE_USDG_USDC_POOL, 1, 0);
        _setCurveRoute(curve, USDG, USDC, CURVE_USDG_USDC_POOL, 0, 1);

        fluid.setBase(USDT);
        fluid.setFluidDex(USDC, USDT, FLUID_USDC_USDT);
        fluid.setFluidDex(USDE, USDT, FLUID_USDE_USDT);
        fluid.setFluidDex(SUSDE, USDT, FLUID_SUSDE_USDT);
        fluid.setFluidDex(USDE, USDTB, FLUID_USDE_USDTB);
        fluid.setFluidBaseForPair(USDE, USDTB, USDE);

        pendle.setPendleMarket(PT_USDG_24_SEP_2026, PENDLE_USDG_MARKET);
        pendle.setGuessMaxMultiplier(2);

        syrup.setSyrupDepositConfig(SYRUP_USDC, SYRUP_USDC_ROUTER, SYRUP_DEPOSIT_DATA);
        syrup.setSyrupDepositConfig(SYRUP_USDT, SYRUP_USDT_ROUTER, SYRUP_DEPOSIT_DATA);
    }

    function _allowVenues(Deployment memory d) internal {
        MetaExchange meta = MetaExchange(payable(d.metaExchange));

        meta.setAllowedExchange(d.uniswapUniversal, true);
        meta.setAllowedExchange(d.curve, true);
        meta.setAllowedExchange(d.fluid, true);
        meta.setAllowedExchange(d.pendle, true);
        meta.setAllowedExchange(d.erc4626, true);
        meta.setAllowedExchange(d.litePsm, true);
        meta.setAllowedExchange(d.syrupDeposit, true);
        meta.setAllowedExchange(d.susds, true);
        meta.setAllowedExchange(d.originMint, true);

        meta.setContextAwareExchange(d.syrupDeposit, true);
        SyrupDepositExchange(d.syrupDeposit).setAllowedForwarder(d.metaExchange, true);
    }

    function _configureRoutes(Deployment memory d) internal {
        MetaExchange meta = MetaExchange(payable(d.metaExchange));

        _setRoute2(meta, PYUSD, SYRUP_USDC, d.curve, USDC, d.syrupDeposit, SYRUP_USDC);
        _setRoute2(meta, SYRUP_USDC, PYUSD, d.uniswapUniversal, USDC, d.curve, PYUSD);
        _setRoute3(meta, PYUSD, SUSDE, d.curve, USDC, d.fluid, USDE, d.erc4626, SUSDE);
        _setRoute2(meta, SUSDE, PYUSD, d.fluid, USDC, d.curve, PYUSD);
        _setRoute2(meta, USDE, PYUSD, d.fluid, USDC, d.curve, PYUSD);

        _setRoute3(meta, USDT, SUSDS, d.uniswapUniversal, USDC, d.litePsm, USDS, d.susds, SUSDS);
        _setRoute3(meta, SUSDS, USDT, d.erc4626, USDS, d.litePsm, USDC, d.uniswapUniversal, USDT);
        _setRoute2(meta, USDC, SUSDS, d.litePsm, USDS, d.susds, SUSDS);
        _setRoute2(meta, SUSDS, USDC, d.erc4626, USDS, d.litePsm, USDC);

        _setRoute2(meta, USDC, PT_USDG_24_SEP_2026, d.curve, USDG, d.pendle, PT_USDG_24_SEP_2026);
        _setRoute2(meta, PT_USDG_24_SEP_2026, USDC, d.pendle, USDG, d.curve, USDC);

        _setRoute2(meta, USDC, WOUSD, d.originMint, OUSD, d.erc4626, WOUSD);
        _setRoute2(meta, WOUSD, USDC, d.erc4626, OUSD, d.curve, USDC);

        _setRoute2(meta, USDC, SUSDE, d.fluid, USDE, d.erc4626, SUSDE);
        _setRoute1(meta, SUSDE, USDC, d.fluid, USDC);
        _setRoute1(meta, USDE, USDC, d.fluid, USDC);
        _setRoute2(meta, USDT, SUSDE, d.fluid, USDE, d.erc4626, SUSDE);
        _setRoute1(meta, SUSDE, USDT, d.fluid, USDT);
        _setRoute1(meta, USDE, USDT, d.fluid, USDT);
        _setRoute2(meta, USDTB, SUSDE, d.fluid, USDE, d.erc4626, SUSDE);
        _setRoute2(meta, SUSDE, USDTB, d.fluid, USDE, d.fluid, USDTB);
        _setRoute1(meta, USDE, USDTB, d.fluid, USDTB);

        _setRoute1(meta, USDT, SYRUP_USDT, useSyrupUsdtMint ? d.syrupDeposit : d.uniswapUniversal, SYRUP_USDT);
        _setRoute1(meta, SYRUP_USDT, USDT, d.uniswapUniversal, USDT);
    }

    function _setOperators(Deployment memory d) internal {
        MetaExchange(payable(d.metaExchange)).setOperator(EXCHANGE_OPERATOR, true);
        UniswapUniversalRouterExchange(payable(d.uniswapUniversal)).setOperator(EXCHANGE_OPERATOR, true);
        CurveExchange(d.curve).setOperator(EXCHANGE_OPERATOR, true);
        FluidExchange(payable(d.fluid)).setOperator(EXCHANGE_OPERATOR, true);
        PendleExchange(d.pendle).setOperator(EXCHANGE_OPERATOR, true);
    }

    function _configureThroughMulticall(Deployment memory d) internal {
        uint256 callCount = 61;
        if (syrupUsdtUniFee != 0) {
            ++callCount;
        }

        GovernanceMulticall.Call[] memory calls = new GovernanceMulticall.Call[](callCount);
        uint256 index;

        index = _appendVenueConfigCalls(calls, index, d);
        index = _appendAllowVenueCalls(calls, index, d);
        index = _appendRouteConfigCalls(calls, index, d);
        index = _appendOperatorCalls(calls, index, d);

        require(index == calls.length, "!calls");
        deploymentMulticall.multicall(calls);
    }

    function _appendVenueConfigCalls(GovernanceMulticall.Call[] memory calls, uint256 index, Deployment memory d)
        internal
        view
        returns (uint256)
    {
        index = _appendCall(
            calls, index, d.uniswapUniversal, abi.encodeCall(UniswapUniversalRouterExchange.setBase, (USDC))
        );
        index = _appendCall(
            calls,
            index,
            d.uniswapUniversal,
            abi.encodeCall(UniswapUniversalRouterExchange.setUniFees, (USDT, USDC, 100))
        );
        index = _appendCall(
            calls,
            index,
            d.uniswapUniversal,
            abi.encodeCall(UniswapUniversalRouterExchange.setV4Pool, (USDC, SYRUP_USDC, SYRUP_USDC_USDC_V4_POOL_ID))
        );
        index = _appendCall(
            calls,
            index,
            d.uniswapUniversal,
            abi.encodeCall(UniswapUniversalRouterExchange.setV4Pool, (USDT, SYRUP_USDT, syrupUsdtV4PoolId))
        );
        if (syrupUsdtUniFee != 0) {
            index = _appendCall(
                calls,
                index,
                d.uniswapUniversal,
                abi.encodeCall(UniswapUniversalRouterExchange.setUniFees, (USDT, SYRUP_USDT, syrupUsdtUniFee))
            );
        }

        index = _appendCurveRouteCall(calls, index, d.curve, PYUSD, USDC, PYUSD_USDC_CURVE_POOL, 0, 1);
        index = _appendCurveRouteCall(calls, index, d.curve, USDC, PYUSD, PYUSD_USDC_CURVE_POOL, 1, 0);
        index = _appendCurveRouteCall(calls, index, d.curve, USDC, USDTB, CURVE_USDC_USDTB_POOL, 0, 1);
        index = _appendCurveRouteCall(calls, index, d.curve, USDTB, USDC, CURVE_USDC_USDTB_POOL, 1, 0);
        index = _appendCurveRouteCall(calls, index, d.curve, OUSD, USDC, CURVE_OUSD_USDC_POOL, 0, 1);
        index = _appendCurveRouteCall(calls, index, d.curve, USDC, USDG, CURVE_USDG_USDC_POOL, 1, 0);
        index = _appendCurveRouteCall(calls, index, d.curve, USDG, USDC, CURVE_USDG_USDC_POOL, 0, 1);

        index = _appendCall(calls, index, d.fluid, abi.encodeCall(FluidExchange.setBase, (USDT)));
        index = _appendCall(
            calls,
            index,
            d.fluid,
            abi.encodeWithSignature("setFluidDex(address,address,address)", USDC, USDT, FLUID_USDC_USDT)
        );
        index = _appendCall(
            calls,
            index,
            d.fluid,
            abi.encodeWithSignature("setFluidDex(address,address,address)", USDE, USDT, FLUID_USDE_USDT)
        );
        index = _appendCall(
            calls,
            index,
            d.fluid,
            abi.encodeWithSignature("setFluidDex(address,address,address)", SUSDE, USDT, FLUID_SUSDE_USDT)
        );
        index = _appendCall(
            calls,
            index,
            d.fluid,
            abi.encodeWithSignature("setFluidDex(address,address,address)", USDE, USDTB, FLUID_USDE_USDTB)
        );
        index =
            _appendCall(calls, index, d.fluid, abi.encodeCall(FluidExchange.setFluidBaseForPair, (USDE, USDTB, USDE)));

        index = _appendCall(
            calls,
            index,
            d.pendle,
            abi.encodeCall(PendleExchange.setPendleMarket, (PT_USDG_24_SEP_2026, PENDLE_USDG_MARKET))
        );
        index = _appendCall(calls, index, d.pendle, abi.encodeCall(PendleExchange.setGuessMaxMultiplier, (2)));

        index = _appendCall(
            calls,
            index,
            d.syrupDeposit,
            abi.encodeCall(
                SyrupDepositExchange.setSyrupDepositConfig, (SYRUP_USDC, SYRUP_USDC_ROUTER, SYRUP_DEPOSIT_DATA)
            )
        );
        index = _appendCall(
            calls,
            index,
            d.syrupDeposit,
            abi.encodeCall(
                SyrupDepositExchange.setSyrupDepositConfig, (SYRUP_USDT, SYRUP_USDT_ROUTER, SYRUP_DEPOSIT_DATA)
            )
        );

        return index;
    }

    function _appendAllowVenueCalls(GovernanceMulticall.Call[] memory calls, uint256 index, Deployment memory d)
        internal
        pure
        returns (uint256)
    {
        index = _appendCall(
            calls, index, d.metaExchange, abi.encodeCall(MetaExchange.setAllowedExchange, (d.uniswapUniversal, true))
        );
        index =
            _appendCall(calls, index, d.metaExchange, abi.encodeCall(MetaExchange.setAllowedExchange, (d.curve, true)));
        index =
            _appendCall(calls, index, d.metaExchange, abi.encodeCall(MetaExchange.setAllowedExchange, (d.fluid, true)));
        index = _appendCall(
            calls, index, d.metaExchange, abi.encodeCall(MetaExchange.setAllowedExchange, (d.pendle, true))
        );
        index = _appendCall(
            calls, index, d.metaExchange, abi.encodeCall(MetaExchange.setAllowedExchange, (d.erc4626, true))
        );
        index = _appendCall(
            calls, index, d.metaExchange, abi.encodeCall(MetaExchange.setAllowedExchange, (d.litePsm, true))
        );
        index = _appendCall(
            calls, index, d.metaExchange, abi.encodeCall(MetaExchange.setAllowedExchange, (d.syrupDeposit, true))
        );
        index =
            _appendCall(calls, index, d.metaExchange, abi.encodeCall(MetaExchange.setAllowedExchange, (d.susds, true)));
        index = _appendCall(
            calls, index, d.metaExchange, abi.encodeCall(MetaExchange.setAllowedExchange, (d.originMint, true))
        );
        index = _appendCall(
            calls, index, d.metaExchange, abi.encodeCall(MetaExchange.setContextAwareExchange, (d.syrupDeposit, true))
        );
        index = _appendCall(
            calls,
            index,
            d.syrupDeposit,
            abi.encodeCall(SyrupDepositExchange.setAllowedForwarder, (d.metaExchange, true))
        );

        return index;
    }

    function _appendRouteConfigCalls(GovernanceMulticall.Call[] memory calls, uint256 index, Deployment memory d)
        internal
        view
        returns (uint256)
    {
        index = _appendRoute2Call(
            calls, index, d.metaExchange, PYUSD, SYRUP_USDC, d.curve, USDC, d.syrupDeposit, SYRUP_USDC
        );
        index = _appendRoute2Call(
            calls, index, d.metaExchange, SYRUP_USDC, PYUSD, d.uniswapUniversal, USDC, d.curve, PYUSD
        );
        index = _appendRoute3Call(
            calls, index, d.metaExchange, PYUSD, SUSDE, d.curve, USDC, d.fluid, USDE, d.erc4626, SUSDE
        );
        index = _appendRoute2Call(calls, index, d.metaExchange, SUSDE, PYUSD, d.fluid, USDC, d.curve, PYUSD);
        index = _appendRoute2Call(calls, index, d.metaExchange, USDE, PYUSD, d.fluid, USDC, d.curve, PYUSD);
        index = _appendRoute3Call(
            calls, index, d.metaExchange, USDT, SUSDS, d.uniswapUniversal, USDC, d.litePsm, USDS, d.susds, SUSDS
        );
        index = _appendRoute3Call(
            calls, index, d.metaExchange, SUSDS, USDT, d.erc4626, USDS, d.litePsm, USDC, d.uniswapUniversal, USDT
        );
        index = _appendRoute2Call(calls, index, d.metaExchange, USDC, SUSDS, d.litePsm, USDS, d.susds, SUSDS);
        index = _appendRoute2Call(calls, index, d.metaExchange, SUSDS, USDC, d.erc4626, USDS, d.litePsm, USDC);
        index = _appendRoute2Call(
            calls, index, d.metaExchange, USDC, PT_USDG_24_SEP_2026, d.curve, USDG, d.pendle, PT_USDG_24_SEP_2026
        );
        index =
            _appendRoute2Call(calls, index, d.metaExchange, PT_USDG_24_SEP_2026, USDC, d.pendle, USDG, d.curve, USDC);
        index = _appendRoute2Call(calls, index, d.metaExchange, USDC, WOUSD, d.originMint, OUSD, d.erc4626, WOUSD);
        index = _appendRoute2Call(calls, index, d.metaExchange, WOUSD, USDC, d.erc4626, OUSD, d.curve, USDC);
        index = _appendRoute2Call(calls, index, d.metaExchange, USDC, SUSDE, d.fluid, USDE, d.erc4626, SUSDE);
        index = _appendRoute1Call(calls, index, d.metaExchange, SUSDE, USDC, d.fluid, USDC);
        index = _appendRoute1Call(calls, index, d.metaExchange, USDE, USDC, d.fluid, USDC);
        index = _appendRoute2Call(calls, index, d.metaExchange, USDT, SUSDE, d.fluid, USDE, d.erc4626, SUSDE);
        index = _appendRoute1Call(calls, index, d.metaExchange, SUSDE, USDT, d.fluid, USDT);
        index = _appendRoute1Call(calls, index, d.metaExchange, USDE, USDT, d.fluid, USDT);
        index = _appendRoute2Call(calls, index, d.metaExchange, USDTB, SUSDE, d.fluid, USDE, d.erc4626, SUSDE);
        index = _appendRoute2Call(calls, index, d.metaExchange, SUSDE, USDTB, d.fluid, USDE, d.fluid, USDTB);
        index = _appendRoute1Call(calls, index, d.metaExchange, USDE, USDTB, d.fluid, USDTB);
        index = _appendRoute1Call(
            calls,
            index,
            d.metaExchange,
            USDT,
            SYRUP_USDT,
            useSyrupUsdtMint ? d.syrupDeposit : d.uniswapUniversal,
            SYRUP_USDT
        );
        index = _appendRoute1Call(calls, index, d.metaExchange, SYRUP_USDT, USDT, d.uniswapUniversal, USDT);

        return index;
    }

    function _appendOperatorCalls(GovernanceMulticall.Call[] memory calls, uint256 index, Deployment memory d)
        internal
        pure
        returns (uint256)
    {
        bytes memory data = abi.encodeWithSignature("setOperator(address,bool)", EXCHANGE_OPERATOR, true);

        index = _appendCall(calls, index, d.metaExchange, data);
        index = _appendCall(calls, index, d.uniswapUniversal, data);
        index = _appendCall(calls, index, d.curve, data);
        index = _appendCall(calls, index, d.fluid, data);
        index = _appendCall(calls, index, d.pendle, data);

        return index;
    }

    function _appendCurveRouteCall(
        GovernanceMulticall.Call[] memory calls,
        uint256 index,
        address curve,
        address from,
        address to,
        address pool,
        uint256 i,
        uint256 j
    ) internal pure returns (uint256) {
        address[11] memory route;
        route[0] = from;
        route[1] = pool;
        route[2] = to;

        uint256[5][5] memory swapParams;
        swapParams[0] = [i, j, 1, 1, 2];

        address[5] memory pools;

        return _appendCall(
            calls, index, curve, abi.encodeCall(CurveExchange.setCurveRoute, (from, to, route, swapParams, pools))
        );
    }

    function _appendRoute1Call(
        GovernanceMulticall.Call[] memory calls,
        uint256 index,
        address meta,
        address from,
        address to,
        address exchange0,
        address token0
    ) internal pure returns (uint256) {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](1);
        route[0] = MetaExchange.RouteStep({exchange: exchange0, tokenFrom: from, tokenTo: token0});

        return _appendCall(calls, index, meta, abi.encodeCall(MetaExchange.setRoute, (from, to, route)));
    }

    function _appendRoute2Call(
        GovernanceMulticall.Call[] memory calls,
        uint256 index,
        address meta,
        address from,
        address to,
        address exchange0,
        address token0,
        address exchange1,
        address token1
    ) internal pure returns (uint256) {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](2);
        route[0] = MetaExchange.RouteStep({exchange: exchange0, tokenFrom: from, tokenTo: token0});
        route[1] = MetaExchange.RouteStep({exchange: exchange1, tokenFrom: token0, tokenTo: token1});

        return _appendCall(calls, index, meta, abi.encodeCall(MetaExchange.setRoute, (from, to, route)));
    }

    function _appendRoute3Call(
        GovernanceMulticall.Call[] memory calls,
        uint256 index,
        address meta,
        address from,
        address to,
        address exchange0,
        address token0,
        address exchange1,
        address token1,
        address exchange2,
        address token2
    ) internal pure returns (uint256) {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](3);
        route[0] = MetaExchange.RouteStep({exchange: exchange0, tokenFrom: from, tokenTo: token0});
        route[1] = MetaExchange.RouteStep({exchange: exchange1, tokenFrom: token0, tokenTo: token1});
        route[2] = MetaExchange.RouteStep({exchange: exchange2, tokenFrom: token1, tokenTo: token2});

        return _appendCall(calls, index, meta, abi.encodeCall(MetaExchange.setRoute, (from, to, route)));
    }

    function _appendCall(GovernanceMulticall.Call[] memory calls, uint256 index, address target, bytes memory data)
        internal
        pure
        returns (uint256)
    {
        calls[index] = GovernanceMulticall.Call({target: target, value: 0, data: data});
        return index + 1;
    }

    function _validate(Deployment memory d) internal view {
        MetaExchange meta = MetaExchange(payable(d.metaExchange));
        FluidExchange fluid = FluidExchange(payable(d.fluid));
        PendleExchange pendle = PendleExchange(d.pendle);
        SyrupDepositExchange syrup = SyrupDepositExchange(d.syrupDeposit);
        UniswapUniversalRouterExchange uni = UniswapUniversalRouterExchange(payable(d.uniswapUniversal));

        require(meta.allowedExchanges(d.uniswapUniversal), "!allow uni");
        require(meta.allowedExchanges(d.curve), "!allow curve");
        require(meta.allowedExchanges(d.fluid), "!allow fluid");
        require(meta.allowedExchanges(d.pendle), "!allow pendle");
        require(meta.allowedExchanges(d.erc4626), "!allow 4626");
        require(meta.allowedExchanges(d.litePsm), "!allow psm");
        require(meta.allowedExchanges(d.syrupDeposit), "!allow syrup");
        require(meta.allowedExchanges(d.susds), "!allow susds");
        require(meta.allowedExchanges(d.originMint), "!allow origin");
        require(meta.contextAwareExchanges(d.syrupDeposit), "!context aware syrup");
        require(syrup.allowedForwarders(d.metaExchange), "!syrup forwarder");
        _assertOperators(d);

        require(uni.base() == USDC, "!uni base");
        require(uni.uniFees(USDT, USDC) == 100, "!usdt usdc fee");
        require(fluid.base() == USDT, "!fluid base");
        _assertFluidDex(fluid, USDC, USDT, FLUID_USDC_USDT);
        _assertFluidDex(fluid, USDE, USDT, FLUID_USDE_USDT);
        _assertFluidDex(fluid, SUSDE, USDT, FLUID_SUSDE_USDT);
        _assertFluidDex(fluid, USDE, USDTB, FLUID_USDE_USDTB);
        _assertFluidBaseForPair(fluid, USDE, USDTB, USDE);
        require(pendle.markets(PT_USDG_24_SEP_2026) == PENDLE_USDG_MARKET, "!pendle market");
        require(pendle.guessMaxMultiplier() == 2, "!guess");

        _assertSyrupConfig(syrup, SYRUP_USDC, SYRUP_USDC_ROUTER);
        _assertSyrupConfig(syrup, SYRUP_USDT, SYRUP_USDT_ROUTER);

        _assertRoute2(meta, PYUSD, SYRUP_USDC, d.curve, USDC, d.syrupDeposit, SYRUP_USDC);
        _assertRoute2(meta, SYRUP_USDC, PYUSD, d.uniswapUniversal, USDC, d.curve, PYUSD);
        _assertRoute3(meta, PYUSD, SUSDE, d.curve, USDC, d.fluid, USDE, d.erc4626, SUSDE);
        _assertRoute2(meta, SUSDE, PYUSD, d.fluid, USDC, d.curve, PYUSD);
        _assertRoute2(meta, USDE, PYUSD, d.fluid, USDC, d.curve, PYUSD);
        _assertRoute3(meta, USDT, SUSDS, d.uniswapUniversal, USDC, d.litePsm, USDS, d.susds, SUSDS);
        _assertRoute3(meta, SUSDS, USDT, d.erc4626, USDS, d.litePsm, USDC, d.uniswapUniversal, USDT);
        _assertRoute2(meta, USDC, SUSDS, d.litePsm, USDS, d.susds, SUSDS);
        _assertRoute2(meta, SUSDS, USDC, d.erc4626, USDS, d.litePsm, USDC);
        _assertRoute2(meta, USDC, PT_USDG_24_SEP_2026, d.curve, USDG, d.pendle, PT_USDG_24_SEP_2026);
        _assertRoute2(meta, PT_USDG_24_SEP_2026, USDC, d.pendle, USDG, d.curve, USDC);
        _assertRoute2(meta, USDC, WOUSD, d.originMint, OUSD, d.erc4626, WOUSD);
        _assertRoute2(meta, WOUSD, USDC, d.erc4626, OUSD, d.curve, USDC);
        _assertRoute2(meta, USDC, SUSDE, d.fluid, USDE, d.erc4626, SUSDE);
        _assertRoute1(meta, SUSDE, USDC, d.fluid, USDC);
        _assertRoute1(meta, USDE, USDC, d.fluid, USDC);
        _assertRoute2(meta, USDT, SUSDE, d.fluid, USDE, d.erc4626, SUSDE);
        _assertRoute1(meta, SUSDE, USDT, d.fluid, USDT);
        _assertRoute1(meta, USDE, USDT, d.fluid, USDT);
        _assertRoute2(meta, USDTB, SUSDE, d.fluid, USDE, d.erc4626, SUSDE);
        _assertRoute2(meta, SUSDE, USDTB, d.fluid, USDE, d.fluid, USDTB);
        _assertRoute1(meta, USDE, USDTB, d.fluid, USDTB);
        _assertRoute1(meta, USDT, SYRUP_USDT, useSyrupUsdtMint ? d.syrupDeposit : d.uniswapUniversal, SYRUP_USDT);
        _assertRoute1(meta, SYRUP_USDT, USDT, d.uniswapUniversal, USDT);
    }

    function _setCurveRoute(CurveExchange curve, address from, address to, address pool, uint256 i, uint256 j)
        internal
    {
        address[11] memory route;
        route[0] = from;
        route[1] = pool;
        route[2] = to;

        uint256[5][5] memory swapParams;
        swapParams[0] = [i, j, 1, 1, 2];

        address[5] memory pools;

        curve.setCurveRoute(from, to, route, swapParams, pools);
    }

    function _setRoute1(MetaExchange meta, address from, address to, address exchange0, address token0) internal {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](1);
        route[0] = MetaExchange.RouteStep({exchange: exchange0, tokenFrom: from, tokenTo: token0});
        meta.setRoute(from, to, route);
    }

    function _setRoute2(
        MetaExchange meta,
        address from,
        address to,
        address exchange0,
        address token0,
        address exchange1,
        address token1
    ) internal {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](2);
        route[0] = MetaExchange.RouteStep({exchange: exchange0, tokenFrom: from, tokenTo: token0});
        route[1] = MetaExchange.RouteStep({exchange: exchange1, tokenFrom: token0, tokenTo: token1});
        meta.setRoute(from, to, route);
    }

    function _setRoute3(
        MetaExchange meta,
        address from,
        address to,
        address exchange0,
        address token0,
        address exchange1,
        address token1,
        address exchange2,
        address token2
    ) internal {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](3);
        route[0] = MetaExchange.RouteStep({exchange: exchange0, tokenFrom: from, tokenTo: token0});
        route[1] = MetaExchange.RouteStep({exchange: exchange1, tokenFrom: token0, tokenTo: token1});
        route[2] = MetaExchange.RouteStep({exchange: exchange2, tokenFrom: token1, tokenTo: token2});
        meta.setRoute(from, to, route);
    }

    function _assertRoute1(MetaExchange meta, address from, address to, address exchange0, address token0)
        internal
        view
    {
        MetaExchange.RouteStep[] memory route = meta.getRoute(from, to);
        require(route.length == 1, "!route length");
        require(route[0].exchange == exchange0, "!route exchange 0");
        require(route[0].tokenTo == token0, "!route token 0");
    }

    function _assertRoute2(
        MetaExchange meta,
        address from,
        address to,
        address exchange0,
        address token0,
        address exchange1,
        address token1
    ) internal view {
        MetaExchange.RouteStep[] memory route = meta.getRoute(from, to);
        require(route.length == 2, "!route length");
        require(route[0].exchange == exchange0, "!route exchange 0");
        require(route[0].tokenTo == token0, "!route token 0");
        require(route[1].exchange == exchange1, "!route exchange 1");
        require(route[1].tokenTo == token1, "!route token 1");
    }

    function _assertRoute3(
        MetaExchange meta,
        address from,
        address to,
        address exchange0,
        address token0,
        address exchange1,
        address token1,
        address exchange2,
        address token2
    ) internal view {
        MetaExchange.RouteStep[] memory route = meta.getRoute(from, to);
        require(route.length == 3, "!route length");
        require(route[0].exchange == exchange0, "!route exchange 0");
        require(route[0].tokenTo == token0, "!route token 0");
        require(route[1].exchange == exchange1, "!route exchange 1");
        require(route[1].tokenTo == token1, "!route token 1");
        require(route[2].exchange == exchange2, "!route exchange 2");
        require(route[2].tokenTo == token2, "!route token 2");
    }

    function _assertFluidDex(FluidExchange fluid, address from, address to, address expectedDex) internal view {
        (address dex,) = fluid.fluidDexes(from, to);
        require(dex == expectedDex, "!fluid dex");
    }

    function _assertOperators(Deployment memory d) internal view {
        require(MetaExchange(payable(d.metaExchange)).operators(EXCHANGE_OPERATOR), "!meta operator");
        require(
            UniswapUniversalRouterExchange(payable(d.uniswapUniversal)).operators(EXCHANGE_OPERATOR), "!uni operator"
        );
        require(CurveExchange(d.curve).operators(EXCHANGE_OPERATOR), "!curve operator");
        require(FluidExchange(payable(d.fluid)).operators(EXCHANGE_OPERATOR), "!fluid operator");
        require(PendleExchange(d.pendle).operators(EXCHANGE_OPERATOR), "!pendle operator");
    }

    function _assertFluidBaseForPair(FluidExchange fluid, address token0, address token1, address expectedBase)
        internal
        view
    {
        require(fluid.fluidBases(token0, token1) == expectedBase, "!fluid pair base");
        require(fluid.fluidBases(token1, token0) == expectedBase, "!fluid pair base");
    }

    function _assertSyrupConfig(SyrupDepositExchange syrup, address vault, address expectedRouter) internal view {
        (address router, bytes32 depositData) = syrup.syrupDepositConfigs(vault);
        require(router == expectedRouter, "!syrup router");
        require(depositData == SYRUP_DEPOSIT_DATA, "!syrup data");
    }

    function _assertSyrupPermission(address router, address syrupExchange) internal view {
        address poolManager = ISyrupRouter(router).poolManager();
        IPoolPermissionManager permissionManager = IPoolPermissionManager(ISyrupRouter(router).poolPermissionManager());

        require(
            permissionManager.hasPermission(poolManager, syrupExchange, MAPLE_DEPOSIT_PERMISSION), "!syrup permission"
        );
    }

    function _logDeployment(Deployment memory d) internal view {
        console2.log("MetaExchange:", d.metaExchange);
        console2.log("UniswapUniversalRouterExchange:", d.uniswapUniversal);
        console2.log("CurveExchange:", d.curve);
        console2.log("FluidExchange:", d.fluid);
        console2.log("PendleExchange:", d.pendle);
        console2.log("ERC4626Exchange:", d.erc4626);
        console2.log("LitePsmExchange:", d.litePsm);
        console2.log("SyrupDepositExchange:", d.syrupDeposit);
        console2.log("SUSDSExchange:", d.susds);
        console2.log("OriginMintExchange:", d.originMint);
        if (address(deploymentMulticall) != address(0)) {
            console2.log("DeploymentMulticall:", address(deploymentMulticall));
            console2.log("MulticallGovernance:", governance);
        }
        console2.log("ExchangeGovernance:", exchangeGovernance);
    }
}
