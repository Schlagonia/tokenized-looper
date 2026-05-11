// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {AaveLooper} from "../../../aave/AaveLooper.sol";
import {WETHWstETHExchange} from "../../../periphery/exchanges/WETHWstETHExchange.sol";
import {LidoWstETHCooldownAdapter} from "../../../periphery/cooldowns/LidoWstETHCooldownAdapter.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";

/// @notice Setup for LST (wstETH/WETH) Aave V3 Looper tests
/// @dev Inherits from Setup and overrides strategy deployment and token config
contract SetupAaveLST is Setup {
    WETHWstETHExchange public exchange;
    LidoWstETHCooldownAdapter public cooldownAdapter;

    // Aave V3 Core Mainnet
    address public constant AAVE_ADDRESSES_PROVIDER =
        0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant MORPHO_FLASHLOAN_PROVIDER =
        0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // wstETH/WETH config
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

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
        exchange = new WETHWstETHExchange();

        address expectedCooldownAdapter = vm.computeCreateAddress(
            address(this),
            vm.getNonce(address(this)) + 1
        );

        AaveLooper looper = new AaveLooper(
            address(asset),
            "LST Aave Looper",
            WSTETH,
            AAVE_ADDRESSES_PROVIDER,
            MORPHO_FLASHLOAN_PROVIDER,
            EMODE_CATEGORY_ID,
            address(exchange),
            management,
            expectedCooldownAdapter
        );
        cooldownAdapter = new LidoWstETHCooldownAdapter(address(looper));
        assertEq(
            address(cooldownAdapter),
            expectedCooldownAdapter,
            "!cooldown"
        );
        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        exchange.transferGovernance(management);

        // Guard against inherited ETH balance at this CREATE address on fork state.
        if (address(looper).balance > 0) {
            vm.deal(address(looper), 0);
        }

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
    function accrueYield(uint256 _amount) public virtual override {
        skip(1 days);
        //airdrop(asset, address(strategy), (_amount * 500) / 10_000);
    }
}
