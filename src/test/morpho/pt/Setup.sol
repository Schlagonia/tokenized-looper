// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {MorphoLooper} from "../../../morpho/MorphoLooper.sol";
import {PTExchange} from "../../../periphery/PTExchange.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {Id} from "../../../interfaces/morpho/IMorpho.sol";

/// @notice Setup for PT iUSD/USDC Morpho Looper tests
/// @dev Inherits from Setup and overrides strategy deployment and token config
contract SetupPT is Setup {
    PTExchange public exchange;

    // PT-iUSD/USDC market
    Id public constant PT_MARKET_ID =
        Id.wrap(
            0xdf034d0351a4c0af947e1a37ecd5ccbce60d72eac90de6fcad48c74e2869d14c
        );

    // PT token (collateral)
    address public constant PT_TOKEN =
        0x5DbF246B37E1b9ac5D08bb38233d71322AE7D166; // PT-iUSD-25JUN2026

    // Pendle market for PT swaps
    address public constant PENDLE_MARKET =
        0x517e54f58B5c587726c577ABBcAb3E74aA51161E;

    address public PENDLE_TOKEN;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        _setTokenAddrs();

        // Set asset to USDC (same as base Setup)
        asset = ERC20(tokenAddrs["USDC"]);
        PENDLE_TOKEN = address(asset);
        decimals = asset.decimals();

        // Fuzz amounts for 6 decimal token (USDC)
        maxFuzzAmount = 10e6; // keep generic lever fuzz dormant; live market is too thin
        minFuzzAmount = 10e6; // 100 USDC

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(PT_TOKEN, "PT_TOKEN");
        vm.label(PENDLE_MARKET, "PENDLE_MARKET");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new PTExchange(
            address(asset),
            PT_TOKEN,
            PENDLE_MARKET,
            PENDLE_TOKEN
        );

        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new MorphoLooper(
                    address(asset), // USDC
                    "PT iUSD Jun 25 Morpho Looper",
                    PT_TOKEN, // PT as collateral
                    MORPHO,
                    PT_MARKET_ID,
                    address(exchange),
                    management
                )
            )
        );
        exchange.setStrategy(address(_strategy));

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

        // Set profit max unlock to 0 so oracle doesn't revert after time skip
        _strategy.setProfitMaxUnlockTime(0);

        vm.stopPrank();

        return address(_strategy);
    }

    /// @notice Override accrueYield - airdrop profit instead of skipping time
    /// @dev PT price/oracle paths can get grumpy after large time skips, so we simulate yield via airdrop
    function accrueYield(uint256 _amount) public virtual override {
        // Don't skip time. Pendle/Morpho pricing starts throwing chairs when the clock jumps.
        // Simulate yield by airdropping some profit instead.
        airdrop(asset, address(strategy), _amount / 30);
    }
}
