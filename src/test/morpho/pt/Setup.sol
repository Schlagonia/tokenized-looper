// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {PTMorphoLooper} from "../../../morpho/PTMorphoLooper.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {Id} from "../../../interfaces/morpho/IMorpho.sol";

/// @notice Setup for PT (Pendle PT/USDC) Morpho Looper tests
/// @dev Inherits from Setup and overrides strategy deployment and token config
contract SetupPT is Setup {
    // PT-siUSD/USDC market
    Id public constant PT_MARKET_ID =
        Id.wrap(
            //0x802ec6e878dc9fe6905b8a0a18962dcca10440a87fa2242fbf4a0461c7b0c789 // cUSD market
            0x32b4a75db50a20f7435dfdcf54593a2e96fc97901321d3ab07268941dee93edb // siUSD market
        );

    // PT token (collateral)
    address public constant PT_TOKEN =
        //0x545A490f9ab534AdF409A2E682bc4098f49952e3; // cUSD token
        0x5510B080449d5E3Bf345b6635eD40A35B36b081f; // siUSD token

    // Pendle market for PT swaps
    address public constant PENDLE_MARKET =
        //0x307c15f808914Df5a5DbE17E5608f84953fFa023; //  cUSD market
        0x126b8f10B8a6f3D3Dbe5dc991cEB14ABa6345E04; // siUSD market

    address public PENDLE_TOKEN;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        _setTokenAddrs();

        // Set asset to USDC (same as base Setup)
        asset = ERC20(tokenAddrs["USDC"]);
        PENDLE_TOKEN = address(asset);
        decimals = asset.decimals();

        // Fuzz amounts for 6 decimal token (USDC)
        maxFuzzAmount = 100_000e6; // up to 100,000,000 USDC
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
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new PTMorphoLooper(
                    address(asset), // USDC
                    "PT Morpho Looper",
                    PT_TOKEN, // PT as collateral
                    MORPHO,
                    PT_MARKET_ID,
                    PENDLE_MARKET,
                    PENDLE_TOKEN // pendleToken = USDC
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

    /// @notice Override accrueYield - airdrop profit instead of skipping time
    /// @dev The cUSD oracle becomes stale after time skip, so we simulate yield via airdrop
    function accrueYield() public virtual override {
        // Don't skip time - the cUSD oracle has staleness checks that will revert
        // Instead, simulate yield by airdropping some profit
        airdrop(asset, address(strategy), 5e6);
    }
}
