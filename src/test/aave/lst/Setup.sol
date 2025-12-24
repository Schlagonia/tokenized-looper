// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {LSTAaveLooper} from "../../../aave/LSTAaveLooper.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";

/// @notice Setup for LST (wstETH/WETH) Aave V3 Looper tests
/// @dev Inherits from Setup and overrides strategy deployment and token config
contract SetupAaveLST is Setup {
    // Aave V3 Core Mainnet
    address public constant AAVE_ADDRESSES_PROVIDER =
        0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    // wstETH/WETH config
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant UNISWAP_V3_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // E-Mode category 1 for ETH-correlated assets (better LTV)
    uint8 public constant EMODE_CATEGORY_ID = 1;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        // Set token addresses for WETH
        tokenAddrs["WETH"] = WETH;
        tokenAddrs["WSTETH"] = WSTETH;

        // Set asset to WETH
        asset = ERC20(WETH);
        decimals = asset.decimals();

        // Fuzz amounts for 18 decimal token (WETH)
        // Keep amounts reasonable for Uniswap liquidity
        maxFuzzAmount = 100e18; // up to 100 WETH
        minFuzzAmount = 0.1e18; // 0.1 WETH

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(WSTETH, "WSTETH");
        vm.label(AAVE_ADDRESSES_PROVIDER, "AAVE_ADDRESSES_PROVIDER");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public virtual override returns (address) {
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new LSTAaveLooper(
                    address(asset),
                    "LST Aave Looper",
                    WSTETH,
                    AAVE_ADDRESSES_PROVIDER,
                    EMODE_CATEGORY_ID,
                    UNISWAP_V3_ROUTER
                )
            )
        );

        _strategy.setPendingManagement(management);

        vm.startPrank(management);
        _strategy.acceptManagement();

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

    /// @notice Override accrueYield - for LST just skip time
    function accrueYield() public virtual override {
        skip(1 days);
    }
}
