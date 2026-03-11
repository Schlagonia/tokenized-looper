// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {SyrupMorphoLooper} from "../../../morpho/SyrupMorphoLooper.sol";
import {SyrupExchange} from "../../../periphery/SyrupExchange.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {Id} from "../../../interfaces/morpho/IMorpho.sol";
import {ISyrupRouter} from "../../../interfaces/syrup/ISyrupRouter.sol";
import {IPoolPermissionManager} from "../../../interfaces/syrup/IPoolPermissionManager.sol";

/// @notice Setup for syrupUSDC/USDC Morpho looper tests
contract SetupSyrupMorpho is Setup {
    SyrupExchange public exchange;
    bytes32 internal constant MAPLE_DEPOSIT_PERMISSION = bytes32("P:deposit");

    // Provided market id (syrupUSDC/USDC)
    Id public constant SYRUP_USDC_MARKET_ID =
        Id.wrap(
            0x729badf297ee9f2f6b3f717b96fd355fc6ec00422284ce1968e76647b258cf44
        );

    // Market params fetched from on-chain market id:
    // loanToken: USDC, collateralToken: syrupUSDC
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
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

        tokenAddrs["USDC"] = USDC;
        tokenAddrs["SYRUP_USDC"] = SYRUP_USDC;

        asset = ERC20(USDC);
        decimals = asset.decimals();

        // Keep conservative while pool-level limits evolve.
        maxFuzzAmount = 50_000e6;
        minFuzzAmount = 100e6;

        strategy = IStrategyInterface(setUpStrategy());
        factory = strategy.FACTORY();

        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(SYRUP_USDC, "SYRUP_USDC");
        vm.label(USDC, "USDC");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new SyrupExchange(
            WETH,
            address(asset),
            SYRUP_USDC,
            SYRUP_USDC_ROUTER
        );

        SyrupMorphoLooper looper = new SyrupMorphoLooper(
            address(asset),
            "syrupUSDC/USDC Morpho Looper",
            SYRUP_USDC,
            MORPHO,
            SYRUP_USDC_MARKET_ID,
            address(exchange),
            management
        );

        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        exchange.setStrategy(address(_strategy));
        _strategy.setPendingManagement(management);

        vm.prank(management);
        _strategy.acceptManagement();

        bool useMint = vm.envOr("SYRUP_MAINNET_USE_MINT", false);
        if (useMint) {
            _authorizeExchangeForSyrupDeposit();
        }

        vm.startPrank(management);
        exchange.setBase(address(asset));
        exchange.setV4Pool(
            address(asset),
            SYRUP_USDC,
            SYRUP_USDC_USDC_V4_POOL_ID
        );
        exchange.setMint(useMint);

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

    function _authorizeExchangeForSyrupDeposit() internal {
        address router = exchange.SYRUP_ROUTER();
        address poolManager = ISyrupRouter(router).poolManager();
        address permissionManager = ISyrupRouter(router)
            .poolPermissionManager();

        address[] memory lenders = new address[](1);
        lenders[0] = address(exchange);
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
                address(exchange),
                MAPLE_DEPOSIT_PERMISSION
            ),
            "!deposit permission"
        );
    }
}
