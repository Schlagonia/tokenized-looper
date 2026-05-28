// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExchange} from "../../interfaces/IExchange.sol";
import {IPoolPermissionManager} from "../../interfaces/syrup/IPoolPermissionManager.sol";
import {ISyrupRouter} from "../../interfaces/syrup/ISyrupRouter.sol";
import {MetaExchange} from "../../periphery/MetaExchange.sol";
import {CurveExchange} from "../../periphery/CurveExchange.sol";
import {ERC4626Exchange} from "../../periphery/ERC4626Exchange.sol";
import {FluidExchange} from "../../periphery/FluidExchange.sol";
import {LitePsmExchange} from "../../periphery/LitePsmExchange.sol";
import {OriginMintExchange} from "../../periphery/OriginMintExchange.sol";
import {SUSDSExchange} from "../../periphery/SUSDSExchange.sol";
import {SyrupDepositExchange} from "../../periphery/SyrupDepositExchange.sol";
import {UniswapUniversalRouterExchange} from "../../periphery/UniswapUniversalRouterExchange.sol";

contract MockStrategyForExchange {
    using SafeERC20 for ERC20;

    IExchange public exchange;

    function setExchange(address _exchange) external {
        exchange = IExchange(_exchange);
    }

    function approveToken(
        address token,
        address spender,
        uint256 amount
    ) external {
        ERC20(token).forceApprove(spender, amount);
    }

    function swap(
        address from,
        address to,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        return exchange.exchange(from, to, amountIn, minAmountOut);
    }
}

contract MetaExchangeForkTest is Test {
    bytes32 internal constant MAPLE_DEPOSIT_PERMISSION = bytes32("P:deposit");

    UniswapUniversalRouterExchange internal uniExchange;
    CurveExchange internal curveExchange;
    FluidExchange internal fluidExchange;
    ERC4626Exchange internal erc4626Exchange;
    LitePsmExchange internal litePsmExchange;
    SUSDSExchange internal susdsExchange;
    SyrupDepositExchange internal syrupExchange;
    OriginMintExchange internal originExchange;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant CURVE_ROUTER =
        0xF0d4c12A5768D806021F80a262B4d39d26C58b8D;
    address internal constant UNISWAP_ROUTER =
        0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant UNISWAP_POSITION_MANAGER =
        0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant SUSDE =
        0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address internal constant SUSDS =
        0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address internal constant OUSD = 0x2A8e1E676Ec238d8A992307B495b45B3fEAa5e86;
    address internal constant WOUSD =
        0xD2af830E8CBdFed6CC11Bab697bB25496ed6FA62;
    address internal constant PYUSD =
        0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address internal constant PYUSD_USDC_CURVE_POOL =
        0x383E6b4437b59fff47B619CBA855CA29342A8559;
    address internal constant CURVE_OUSD_USDC_POOL =
        0x6d18E1a7faeB1F0467A77C0d293872ab685426dc;
    address internal constant SYRUP_USDC =
        0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;
    address internal constant SYRUP_USDC_ROUTER =
        0x134cCaaA4F1e4552eC8aEcb9E4A2360dDcF8df76;
    bytes32 internal constant SYRUP_USDC_USDC_V4_POOL_ID =
        0xcdb422a853a4fa2deb364317db92ad76d1cb7a8e1b82a32219bcb41720a90228;
    address internal constant FLUID_USDE_USDT =
        0xf063BD202E45d6b2843102cb4EcE339026645D4a;
    address internal constant LITE_PSM_WRAPPER =
        0xA188EEC8F81263234dA3622A406892F3D630f98c;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
    }

    function test_fork_swap_pyusd_to_syrupUsdc() public {
        (MetaExchange exchange, MockStrategyForExchange strategy) = _deploy();

        _configureSyrupPyusdRoutes(exchange);
        _authorizeExchangeForSyrupDeposit(address(syrupExchange));

        uint256 amountIn = 10_000e6;
        deal(PYUSD, address(strategy), amountIn);
        strategy.approveToken(PYUSD, address(exchange), type(uint256).max);

        uint256 sharesOut = strategy.swap(PYUSD, SYRUP_USDC, amountIn, 0);
        uint256 assetValue = IERC4626(SYRUP_USDC).convertToAssets(sharesOut);

        assertGt(sharesOut, 0, "!sharesOut");
        assertGt(assetValue, 9_700e6, "!assetValue");
        assertEq(
            ERC20(SYRUP_USDC).balanceOf(address(strategy)),
            sharesOut,
            "!recv"
        );
    }

    function test_fork_swap_syrupUsdc_to_pyusd() public {
        (MetaExchange exchange, MockStrategyForExchange strategy) = _deploy();

        _configureSyrupPyusdRoutes(exchange);

        uint256 sharesIn = IERC4626(SYRUP_USDC).previewDeposit(10_000e6);
        deal(SYRUP_USDC, address(strategy), sharesIn);
        strategy.approveToken(SYRUP_USDC, address(exchange), type(uint256).max);

        uint256 amountOut = strategy.swap(SYRUP_USDC, PYUSD, sharesIn, 0);

        assertGt(amountOut, 9_700e6, "!amountOut");
        assertEq(ERC20(PYUSD).balanceOf(address(strategy)), amountOut, "!recv");
    }

    function test_fork_swap_usdt_to_susde() public {
        (MetaExchange exchange, MockStrategyForExchange strategy) = _deploy();

        fluidExchange.setBase(USDT);
        fluidExchange.setFluidDex(USDE, USDT, FLUID_USDE_USDT);

        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](2);
        route[0] = MetaExchange.RouteStep({
            exchange: address(fluidExchange),
            tokenFrom: USDT,
            tokenTo: USDE
        });
        route[1] = MetaExchange.RouteStep({
            exchange: address(erc4626Exchange),
            tokenFrom: USDE,
            tokenTo: SUSDE
        });
        exchange.setRoute(USDT, SUSDE, route);

        uint256 amountIn = 10_000e6;
        deal(USDT, address(strategy), amountIn);
        strategy.approveToken(USDT, address(exchange), type(uint256).max);

        uint256 sharesOut = strategy.swap(USDT, SUSDE, amountIn, 0);
        uint256 assetValue = IERC4626(SUSDE).convertToAssets(sharesOut);

        assertGt(sharesOut, 0, "!sharesOut");
        assertGt(assetValue, 9_700e18, "!assetValue");
        assertEq(ERC20(SUSDE).balanceOf(address(strategy)), sharesOut, "!recv");
    }

    function test_fork_swap_usdc_to_susds() public {
        (MetaExchange exchange, MockStrategyForExchange strategy) = _deploy();

        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](2);
        route[0] = MetaExchange.RouteStep({
            exchange: address(litePsmExchange),
            tokenFrom: USDC,
            tokenTo: USDS
        });
        route[1] = MetaExchange.RouteStep({
            exchange: address(susdsExchange),
            tokenFrom: USDS,
            tokenTo: SUSDS
        });
        exchange.setRoute(USDC, SUSDS, route);

        uint256 amountIn = 10_000e6;
        deal(USDC, address(strategy), amountIn);
        strategy.approveToken(USDC, address(exchange), type(uint256).max);

        uint256 sharesOut = strategy.swap(USDC, SUSDS, amountIn, 0);
        uint256 assetValue = IERC4626(SUSDS).convertToAssets(sharesOut);

        assertGt(sharesOut, 0, "!sharesOut");
        assertGt(assetValue, 9_999e18, "!assetValue");
        assertEq(ERC20(SUSDS).balanceOf(address(strategy)), sharesOut, "!recv");
    }

    function test_fork_swap_usdc_to_wousd() public {
        (MetaExchange exchange, MockStrategyForExchange strategy) = _deploy();

        _configureOriginRoutes(exchange);

        uint256 amountIn = 10_000e6;
        deal(USDC, address(strategy), amountIn);
        strategy.approveToken(USDC, address(exchange), type(uint256).max);

        uint256 sharesOut = strategy.swap(USDC, WOUSD, amountIn, 0);
        uint256 assetValue = IERC4626(WOUSD).convertToAssets(sharesOut);

        assertGt(sharesOut, 0, "!sharesOut");
        assertGt(assetValue, 9_999e18, "!assetValue");
        assertEq(ERC20(WOUSD).balanceOf(address(strategy)), sharesOut, "!recv");
    }

    function _deploy()
        internal
        returns (MetaExchange exchange, MockStrategyForExchange strategy)
    {
        exchange = new MetaExchange(address(this));
        uniExchange = new UniswapUniversalRouterExchange(
            WETH,
            UNISWAP_ROUTER,
            UNISWAP_POSITION_MANAGER,
            address(this)
        );
        curveExchange = new CurveExchange(CURVE_ROUTER, address(this));
        fluidExchange = new FluidExchange(WETH, address(this));
        erc4626Exchange = new ERC4626Exchange(address(this));
        litePsmExchange = new LitePsmExchange(
            USDC,
            USDS,
            LITE_PSM_WRAPPER,
            1e12,
            address(this)
        );
        susdsExchange = new SUSDSExchange(address(this));
        syrupExchange = new SyrupDepositExchange(address(this));
        originExchange = new OriginMintExchange(address(this));
        strategy = new MockStrategyForExchange();

        exchange.setAllowedExchange(address(uniExchange), true);
        exchange.setAllowedExchange(address(curveExchange), true);
        exchange.setAllowedExchange(address(fluidExchange), true);
        exchange.setAllowedExchange(address(erc4626Exchange), true);
        exchange.setAllowedExchange(address(litePsmExchange), true);
        exchange.setAllowedExchange(address(susdsExchange), true);
        exchange.setAllowedExchange(address(syrupExchange), true);
        exchange.setAllowedExchange(address(originExchange), true);
        exchange.setContextAwareExchange(address(syrupExchange), true);
        syrupExchange.setAllowedForwarder(address(exchange), true);

        strategy.setExchange(address(exchange));
        syrupExchange.setAllowed(address(strategy), true);
    }

    function _configureSyrupPyusdRoutes(MetaExchange exchange) internal {
        uniExchange.setBase(USDC);
        uniExchange.setV4Pool(USDC, SYRUP_USDC, SYRUP_USDC_USDC_V4_POOL_ID);
        _setCurveRoute(exchange, PYUSD, USDC, PYUSD_USDC_CURVE_POOL, 0, 1);
        _setCurveRoute(exchange, USDC, PYUSD, PYUSD_USDC_CURVE_POOL, 1, 0);
        syrupExchange.setSyrupDepositConfig(
            SYRUP_USDC,
            SYRUP_USDC_ROUTER,
            bytes32("Yearn")
        );

        MetaExchange.RouteStep[] memory forward = new MetaExchange.RouteStep[](
            2
        );
        forward[0] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenFrom: PYUSD,
            tokenTo: USDC
        });
        forward[1] = MetaExchange.RouteStep({
            exchange: address(syrupExchange),
            tokenFrom: USDC,
            tokenTo: SYRUP_USDC
        });
        exchange.setRoute(PYUSD, SYRUP_USDC, forward);

        MetaExchange.RouteStep[] memory reverse = new MetaExchange.RouteStep[](
            2
        );
        reverse[0] = MetaExchange.RouteStep({
            exchange: address(uniExchange),
            tokenFrom: SYRUP_USDC,
            tokenTo: USDC
        });
        reverse[1] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenFrom: USDC,
            tokenTo: PYUSD
        });
        exchange.setRoute(SYRUP_USDC, PYUSD, reverse);
    }

    function _configureOriginRoutes(MetaExchange exchange) internal {
        _setCurveRoute(exchange, OUSD, USDC, CURVE_OUSD_USDC_POOL, 0, 1);

        MetaExchange.RouteStep[] memory forward = new MetaExchange.RouteStep[](
            2
        );
        forward[0] = MetaExchange.RouteStep({
            exchange: address(originExchange),
            tokenFrom: USDC,
            tokenTo: OUSD
        });
        forward[1] = MetaExchange.RouteStep({
            exchange: address(erc4626Exchange),
            tokenFrom: OUSD,
            tokenTo: WOUSD
        });
        exchange.setRoute(USDC, WOUSD, forward);

        MetaExchange.RouteStep[] memory reverse = new MetaExchange.RouteStep[](
            2
        );
        reverse[0] = MetaExchange.RouteStep({
            exchange: address(erc4626Exchange),
            tokenFrom: WOUSD,
            tokenTo: OUSD
        });
        reverse[1] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenFrom: OUSD,
            tokenTo: USDC
        });
        exchange.setRoute(WOUSD, USDC, reverse);
    }

    function _setCurveRoute(
        MetaExchange exchange,
        address from,
        address to,
        address pool,
        uint256 i,
        uint256 j
    ) internal {
        address[11] memory route;
        route[0] = from;
        route[1] = pool;
        route[2] = to;

        uint256[5][5] memory swapParams;
        swapParams[0] = [i, j, 1, 1, 2];

        address[5] memory pools;

        curveExchange.setCurveRoute(from, to, route, swapParams, pools);
    }

    function _authorizeExchangeForSyrupDeposit(address exchange) internal {
        address poolManager = ISyrupRouter(SYRUP_USDC_ROUTER).poolManager();
        address permissionManager = ISyrupRouter(SYRUP_USDC_ROUTER)
            .poolPermissionManager();

        address[] memory lenders = new address[](1);
        lenders[0] = exchange;
        bool[] memory isAllowed = new bool[](1);
        isAllowed[0] = true;

        vm.prank(IPoolPermissionManager(permissionManager).admin());
        IPoolPermissionManager(permissionManager).setLenderAllowlist(
            poolManager,
            lenders,
            isAllowed
        );

        assertTrue(
            IPoolPermissionManager(permissionManager).hasPermission(
                poolManager,
                exchange,
                MAPLE_DEPOSIT_PERMISSION
            ),
            "!deposit permission"
        );
    }
}
