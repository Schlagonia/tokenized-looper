// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {EulerLooper} from "../../../euler/EulerLooper.sol";
import {IEVC} from "../../../interfaces/euler/IEVC.sol";
import {IEVault} from "../../../interfaces/euler/IEVault.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {ISyrupRouter} from "../../../interfaces/syrup/ISyrupRouter.sol";
import {IPoolPermissionManager} from "../../../interfaces/syrup/IPoolPermissionManager.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";
import {CurveExchange} from "../../../periphery/CurveExchange.sol";
import {SyrupDepositExchange} from "../../../periphery/SyrupDepositExchange.sol";
import {UniswapUniversalRouterExchange} from "../../../periphery/UniswapUniversalRouterExchange.sol";

/// @notice Setup for syrupUSDC/RLUSD Euler looper tests.
contract SetupEulerSyrupRLUSD is Setup {
    MetaExchange public exchange;
    CurveExchange public curveExchange;
    UniswapUniversalRouterExchange public uniExchange;
    SyrupDepositExchange public syrupExchange;

    bytes32 internal constant MAPLE_DEPOSIT_PERMISSION = bytes32("P:deposit");
    bytes32 internal constant SYRUP_DEPOSIT_DATA = bytes32("Yearn");

    address public constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant SYRUP_USDC =
        0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;
    address public constant SYRUP_USDC_ROUTER =
        0x134cCaaA4F1e4552eC8aEcb9E4A2360dDcF8df76;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address public constant EULER_SYRUP_USDC_VAULT =
        0x4BC68f0CC010A0BedA0E3f63CfBEcDee5Ad55A18;
    address public constant EULER_RLUSD_VAULT =
        0xaF5372792a29dC6b296d6FFD4AA3386aff8f9BB2;
    address public constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    address public constant RLUSD_USDC_CURVE_POOL =
        0xD001aE433f254283FeCE51d4ACcE8c53263aa186;

    bytes32 public constant SYRUP_USDC_USDC_V4_POOL_ID =
        0xcdb422a853a4fa2deb364317db92ad76d1cb7a8e1b82a32219bcb41720a90228;

    uint256 internal constant MORPHO_RLUSD_FLASHLOAN_SEED = 5_000_000e18;
    uint256 internal constant EULER_RLUSD_LIQUIDITY_SEED = 5_000_000e18;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        user = makeAddr("euler-syrup-rlusd-user");

        tokenAddrs["RLUSD"] = RLUSD;
        tokenAddrs["USDC"] = USDC;
        tokenAddrs["SYRUP_USDC"] = SYRUP_USDC;

        asset = ERC20(RLUSD);
        decimals = asset.decimals();

        maxFuzzAmount = 25_000e18;
        minFuzzAmount = 100e18;

        _openEulerCapsForFork();
        strategy = IStrategyInterface(setUpStrategy());
        _seedMorphoFlashloanLiquidity(MORPHO_RLUSD_FLASHLOAN_SEED);
        _seedEulerBorrowLiquidity(EULER_RLUSD_LIQUIDITY_SEED);
        factory = strategy.FACTORY();

        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(address(exchange), "exchange");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(RLUSD, "RLUSD");
        vm.label(USDC, "USDC");
        vm.label(SYRUP_USDC, "SYRUP_USDC");
        vm.label(EULER_SYRUP_USDC_VAULT, "EULER_SYRUP_USDC_VAULT");
        vm.label(EULER_RLUSD_VAULT, "EULER_RLUSD_VAULT");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new MetaExchange(WETH);
        curveExchange = new CurveExchange(CURVE_ROUTER);
        uniExchange = new UniswapUniversalRouterExchange(
            WETH,
            UNISWAP_ROUTER,
            UNISWAP_POSITION_MANAGER
        );
        syrupExchange = new SyrupDepositExchange();

        EulerLooper looper = new EulerLooper(
            address(asset),
            "syrupUSDC/RLUSD Euler Looper",
            SYRUP_USDC,
            EULER_SYRUP_USDC_VAULT,
            EULER_RLUSD_VAULT,
            MORPHO,
            address(exchange),
            management
        );

        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        exchange.transferGovernance(management);
        curveExchange.transferGovernance(management);
        uniExchange.transferGovernance(management);
        syrupExchange.transferGovernance(management);
        _strategy.setPendingManagement(management);

        _authorizeSyrupDepositExchange();

        vm.startPrank(management);
        _strategy.acceptManagement();

        _setCurveRoute(RLUSD, USDC, 1, 0);
        _setCurveRoute(USDC, RLUSD, 0, 1);

        uniExchange.setBase(USDC);
        uniExchange.setV4Pool(USDC, SYRUP_USDC, SYRUP_USDC_USDC_V4_POOL_ID);
        syrupExchange.setSyrupDepositConfig(
            SYRUP_USDC,
            SYRUP_USDC_ROUTER,
            SYRUP_DEPOSIT_DATA
        );

        exchange.setAllowedExchange(address(curveExchange), true);
        exchange.setAllowedExchange(address(uniExchange), true);
        exchange.setAllowedExchange(address(syrupExchange), true);
        _setRoutes();

        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setEmergencyAdmin(emergencyAdmin);
        _strategy.setAllowed(user, true);
        _strategy.setMaxGasPriceToTend(type(uint256).max);
        _strategy.setProfitMaxUnlockTime(0);
        _strategy.setSlippage(99);

        vm.stopPrank();

        return address(_strategy);
    }

    function accrueYield(uint256 _amount) public virtual override {
        // Keep the fork timestamp stable so Euler's oracle staleness checks stay valid.
        airdrop(asset, address(strategy), (_amount * 300) / 10_000);
    }

    function _setRoutes() internal {
        MetaExchange.RouteStep[] memory forward = new MetaExchange.RouteStep[](
            2
        );
        forward[0] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenTo: USDC
        });
        forward[1] = MetaExchange.RouteStep({
            exchange: address(syrupExchange),
            tokenTo: SYRUP_USDC
        });
        exchange.setRoute(RLUSD, SYRUP_USDC, forward);

        MetaExchange.RouteStep[] memory reverse = new MetaExchange.RouteStep[](
            2
        );
        reverse[0] = MetaExchange.RouteStep({
            exchange: address(uniExchange),
            tokenTo: USDC
        });
        reverse[1] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenTo: RLUSD
        });
        exchange.setRoute(SYRUP_USDC, RLUSD, reverse);
    }

    function _setCurveRoute(
        address from,
        address to,
        uint256 i,
        uint256 j
    ) internal {
        address[11] memory route;
        route[0] = from;
        route[1] = RLUSD_USDC_CURVE_POOL;
        route[2] = to;

        uint256[5][5] memory swapParams;
        swapParams[0] = [i, j, 1, 1, 2];

        address[5] memory pools;

        curveExchange.setCurveRoute(from, to, route, swapParams, pools);
    }

    function _authorizeSyrupDepositExchange() internal {
        address poolManager = ISyrupRouter(SYRUP_USDC_ROUTER).poolManager();
        address permissionManager = ISyrupRouter(SYRUP_USDC_ROUTER)
            .poolPermissionManager();

        address[] memory lenders = new address[](1);
        lenders[0] = address(syrupExchange);
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
                address(syrupExchange),
                MAPLE_DEPOSIT_PERMISSION
            ),
            "!deposit permission"
        );
    }

    function _seedMorphoFlashloanLiquidity(uint256 amount) internal {
        deal(address(asset), MORPHO, asset.balanceOf(MORPHO) + amount);
    }

    function _seedEulerBorrowLiquidity(uint256 amount) internal {
        deal(address(asset), address(this), amount);
        asset.approve(EULER_RLUSD_VAULT, amount);
        IEVault(EULER_RLUSD_VAULT).deposit(amount, address(this));
    }

    function _openEulerCapsForFork() internal {
        (, uint16 collateralBorrowCap) = IEVault(EULER_SYRUP_USDC_VAULT).caps();
        address collateralGovernor = IEVault(EULER_SYRUP_USDC_VAULT)
            .governorAdmin();

        vm.prank(collateralGovernor);
        IEVault(EULER_SYRUP_USDC_VAULT).setCaps(0, collateralBorrowCap);
    }

    function _assertEulerAccountEnabled(address account) internal view {
        assertTrue(
            IEVC(EVC).isCollateralEnabled(account, EULER_SYRUP_USDC_VAULT),
            "!euler collateral"
        );
        assertTrue(
            IEVC(EVC).isControllerEnabled(account, EULER_RLUSD_VAULT),
            "!euler controller"
        );
    }
}
