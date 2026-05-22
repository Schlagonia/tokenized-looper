// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {SyrupMorphoLooper} from "../../../morpho/SyrupMorphoLooper.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {IMorpho, Id, MarketParams} from "../../../interfaces/morpho/IMorpho.sol";
import {ISyrupRouter} from "../../../interfaces/syrup/ISyrupRouter.sol";
import {IPoolPermissionManager} from "../../../interfaces/syrup/IPoolPermissionManager.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";
import {CurveExchange} from "../../../periphery/CurveExchange.sol";
import {SyrupDepositExchange} from "../../../periphery/SyrupDepositExchange.sol";
import {UniswapUniversalRouterExchange} from "../../../periphery/UniswapUniversalRouterExchange.sol";

/// @notice Setup for syrupUSDC/PYUSD Morpho looper tests
contract SetupSyrupMorpho is Setup {
    MetaExchange public exchange;
    UniswapUniversalRouterExchange public uniExchange;
    CurveExchange public curveExchange;
    SyrupDepositExchange public syrupExchange;
    bytes32 internal constant MAPLE_DEPOSIT_PERMISSION = bytes32("P:deposit");
    bytes32 internal constant SYRUP_DEPOSIT_DATA = bytes32("Yearn");

    Id public constant SYRUP_USDC_PYUSD_MARKET_ID =
        Id.wrap(
            0xc9629945524f3fde56c7e8854a6c3d48e76b9d97236abbe73c750fcc7aeb8501
        );

    address public constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant PYUSD_USDC_CURVE_POOL =
        0x383E6b4437b59fff47B619CBA855CA29342A8559;
    address public constant SYRUP_USDC =
        0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;
    address public constant SYRUP_USDC_ROUTER =
        0x134cCaaA4F1e4552eC8aEcb9E4A2360dDcF8df76;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    bytes32 public constant SYRUP_USDC_USDC_V4_POOL_ID =
        0xcdb422a853a4fa2deb364317db92ad76d1cb7a8e1b82a32219bcb41720a90228;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        user = makeAddr("syrup-usdc-user");

        tokenAddrs["PYUSD"] = PYUSD;
        tokenAddrs["USDC"] = USDC;
        tokenAddrs["SYRUP_USDC"] = SYRUP_USDC;

        asset = ERC20(PYUSD);
        decimals = asset.decimals();

        // Keep conservative while pool-level limits evolve.
        maxFuzzAmount = 50_000e6;
        minFuzzAmount = 100e6;

        strategy = IStrategyInterface(setUpStrategy());
        _seedSyrupMorphoLiquidity(MORPHO_LIQUIDITY_SEED);
        factory = strategy.FACTORY();

        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(SYRUP_USDC, "SYRUP_USDC");
        vm.label(PYUSD, "PYUSD");
        vm.label(USDC, "USDC");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new MetaExchange(management);
        uniExchange = new UniswapUniversalRouterExchange(
            WETH,
            UNISWAP_ROUTER,
            UNISWAP_POSITION_MANAGER,
            management
        );
        curveExchange = new CurveExchange(CURVE_ROUTER, management);
        syrupExchange = new SyrupDepositExchange(management);

        SyrupMorphoLooper looper = new SyrupMorphoLooper(
            address(asset),
            "syrupUSDC/PYUSD Morpho Looper",
            SYRUP_USDC,
            USDC,
            MORPHO,
            SYRUP_USDC_PYUSD_MARKET_ID,
            address(exchange),
            management
        );

        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        _strategy.setPendingManagement(management);

        vm.prank(management);
        _strategy.acceptManagement();

        _authorizeSyrupParticipants(address(_strategy));

        vm.startPrank(management);
        uniExchange.setBase(USDC);
        uniExchange.setV4Pool(USDC, SYRUP_USDC, SYRUP_USDC_USDC_V4_POOL_ID);
        _setCurveRoute(PYUSD, USDC, 0, 1);
        _setCurveRoute(USDC, PYUSD, 1, 0);
        syrupExchange.setSyrupDepositConfig(
            SYRUP_USDC,
            SYRUP_USDC_ROUTER,
            SYRUP_DEPOSIT_DATA
        );
        exchange.setAllowedExchange(address(uniExchange), true);
        exchange.setAllowedExchange(address(curveExchange), true);
        exchange.setAllowedExchange(address(syrupExchange), true);
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
        airdrop(asset, address(strategy), (_amount * 300) / 10_000);
    }

    function _setRoutes() internal {
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

        MetaExchange.RouteStep[]
            memory redeemedUnderlying = new MetaExchange.RouteStep[](1);
        redeemedUnderlying[0] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenFrom: USDC,
            tokenTo: PYUSD
        });
        exchange.setRoute(USDC, PYUSD, redeemedUnderlying);
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

    function _seedSyrupMorphoLiquidity(uint256 amount) internal {
        MarketParams memory params = IMorpho(MORPHO).idToMarketParams(
            SYRUP_USDC_PYUSD_MARKET_ID
        );
        deal(address(asset), address(this), amount);
        asset.approve(MORPHO, amount);
        IMorpho(MORPHO).supply(params, amount, 0, address(this), "");
    }

    function _authorizeSyrupParticipants(address _strategy) internal {
        address poolManager = ISyrupRouter(SYRUP_USDC_ROUTER).poolManager();
        address permissionManager = ISyrupRouter(SYRUP_USDC_ROUTER)
            .poolPermissionManager();

        // Allowlist both the exchange (for deposits during tend) and the
        // strategy (for direct-redemption flows: requestRedeem / removeShares).
        address[] memory lenders = new address[](2);
        lenders[0] = address(syrupExchange);
        lenders[1] = _strategy;
        bool[] memory isAllowed = new bool[](2);
        isAllowed[0] = true;
        isAllowed[1] = true;

        vm.prank(IPoolPermissionManager(permissionManager).admin());
        IPoolPermissionManager(permissionManager).setLenderAllowlist(
            poolManager,
            lenders,
            isAllowed
        );

        assertTrue(
            IPoolPermissionManager(permissionManager).hasPermission(
                poolManager,
                address(syrupExchange),
                MAPLE_DEPOSIT_PERMISSION
            ),
            "!deposit permission"
        );
    }
}
