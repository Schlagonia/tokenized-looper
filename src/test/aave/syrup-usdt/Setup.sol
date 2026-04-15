// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {SyrupUSDTAaveLooper} from "../../../aave/SyrupUSDTAaveLooper.sol";
import {SyrupExchange} from "../../../periphery/SyrupExchange.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {ISyrupRouter} from "../../../interfaces/syrup/ISyrupRouter.sol";
import {IPoolPermissionManager} from "../../../interfaces/syrup/IPoolPermissionManager.sol";

/// @notice Setup for syrupUSDT/USDT Aave V3 looper tests
contract SetupAaveSyrupUSDT is Setup {
    SyrupExchange public exchange;
    bytes32 internal constant MAPLE_DEPOSIT_PERMISSION = bytes32("P:deposit");

    // Aave V3 core (Ethereum mainnet)
    address public constant AAVE_ADDRESSES_PROVIDER =
        0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant MORPHO_FLASHLOAN_PROVIDER =
        0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // Token config
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant SYRUP_USDT =
        0x356B8d89c1e1239Cbbb9dE4815c39A1474d5BA7D;
    address public constant SYRUP_USDT_ROUTER =
        0xF007476Bb27430795138C511F18F821e8D1e5Ee2;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Use category 0 unless strategy-specific eMode is confirmed for this pair.
    uint8 public constant EMODE_CATEGORY_ID = 0;

    // Provide via env var when running tests:
    // export SYRUP_USDT_V4_POOL_ID=0x...
    bytes32 public syrupUsdtV4PoolId;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        syrupUsdtV4PoolId = vm.envOr(
            "SYRUP_USDT_V4_POOL_ID",
            bytes32(
                0xd861038a98942312d1495dd1313fb66c7e7de48f549a15edf3a45decf7338e1d
            )
        );

        tokenAddrs["USDT"] = USDT;
        tokenAddrs["SYRUP_USDT"] = SYRUP_USDT;

        asset = ERC20(USDT);
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
        vm.label(SYRUP_USDT, "SYRUP_USDT");
        vm.label(AAVE_ADDRESSES_PROVIDER, "AAVE_ADDRESSES_PROVIDER");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new SyrupExchange(
            WETH,
            address(asset),
            SYRUP_USDT,
            SYRUP_USDT_ROUTER
        );

        SyrupUSDTAaveLooper looper = new SyrupUSDTAaveLooper(
            address(asset),
            "syrupUSDT Aave Looper",
            SYRUP_USDT,
            AAVE_ADDRESSES_PROVIDER,
            MORPHO_FLASHLOAN_PROVIDER,
            EMODE_CATEGORY_ID,
            address(exchange),
            management
        );

        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        exchange.transferGovernance(management);
        _strategy.setPendingManagement(management);

        vm.prank(management);
        _strategy.acceptManagement();

        bool useMint = vm.envOr("SYRUP_MAINNET_USE_MINT", true);
        if (useMint) {
            _authorizeExchangeForSyrupDeposit();
        }

        vm.startPrank(management);
        exchange.setBase(address(asset));
        exchange.setV4Pool(address(asset), SYRUP_USDT, syrupUsdtV4PoolId);
        exchange.setMint(useMint);

        // Optional: force v3 route if SYRUP_USDT_UNI_FEE is set.
        uint24 uniFee = uint24(vm.envOr("SYRUP_USDT_UNI_FEE", uint256(0)));
        if (uniFee != 0) {
            exchange.setUniFees(USDT, SYRUP_USDT, uniFee);
        }

        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setEmergencyAdmin(emergencyAdmin);

        // Allow first reports without tripping health check.
        _strategy.setAllowed(user, true);

        // Set high gas price tolerance for testing
        _strategy.setMaxGasPriceToTend(type(uint256).max);

        vm.stopPrank();

        return address(_strategy);
    }

    function accrueYield(uint256 _amount) public virtual override {
        skip(1 days);
        airdrop(asset, address(strategy), (_amount * 500) / 10_000);
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
