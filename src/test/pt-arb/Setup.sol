// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../base/Setup.sol";
import {sUSDaiPTLooper} from "../../sUSDaiPTLooper.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {Id} from "../../interfaces/morpho/IMorpho.sol";

/// @notice Setup for sUSDai PT Morpho Looper tests on Arbitrum
/// @dev Inherits from Setup and overrides for Arbitrum network
contract SetupPTArb is Setup {
    // Arbitrum Morpho
    address public constant ARB_MORPHO =
        0x6c247b1F6182318877311737BaC0844bAa518F5e;

    // Market config
    Id public constant PT_MARKET_ID =
        Id.wrap(
            0x7717f1e04510390518811b3133ea47c298094ddd1d806ed8f8867d88c727bad7
        );

    // PT token (collateral)
    address public constant PT_TOKEN =
        0x1BF1311FCF914A69Dd5805C9B06b72F80539cB3f;

    // Pendle market for PT swaps
    address public constant PENDLE_MARKET =
        0x2092Fa5d02276B3136A50F3C2C3a6Ed45413183E;

    // Pendle token (sUSDai) - intermediate for USDC <-> PT conversion
    address public constant PENDLE_TOKEN =
        0x0B2b2B2076d95dda7817e785989fE353fe955ef9;

    // Arbitrum USDC
    address public constant ARB_USDC =
        0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ARB_RPC_URL"));

        // Set asset to Arbitrum USDC
        asset = ERC20(ARB_USDC);
        decimals = asset.decimals();

        // Fuzz amounts for 6 decimal token (USDC)
        // Keep smaller amounts due to limited liquidity in Arbitrum pool
        maxFuzzAmount = 10_000e6; // 10K USDC max
        minFuzzAmount = 10e6;

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
        vm.label(PENDLE_TOKEN, "PENDLE_TOKEN");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public virtual override returns (address) {
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new sUSDaiPTLooper(
                    address(asset), // USDC
                    "sUSDai PT Morpho Looper",
                    PT_TOKEN, // PT as collateral
                    ARB_MORPHO,
                    PT_MARKET_ID,
                    PENDLE_MARKET,
                    PENDLE_TOKEN // sUSDai
                )
            )
        );

        _strategy.setPendingManagement(management);

        vm.startPrank(management);
        _strategy.acceptManagement();

        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setEmergencyAdmin(emergencyAdmin);

        _strategy.setAllowed(user, true);

        // Set high gas price tolerance for testing
        _strategy.setMaxGasPriceToTend(type(uint256).max);

        vm.stopPrank();

        return address(_strategy);
    }

    /// @notice Override accrueYield - airdrop profit instead of skipping time
    /// @dev Oracle may have staleness checks that will revert after time skip
    function accrueYield(uint256 _amount) public virtual override {
        skip(1 days);
        airdrop(asset, address(strategy), _amount / 10);
    }
}
