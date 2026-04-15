// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {MorphoLooper} from "../../../morpho/MorphoLooper.sol";
import {CurvePTExchange} from "../../../periphery/CurvePTExchange.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {IMorpho, Id, MarketParams} from "../../../interfaces/morpho/IMorpho.sol";

/// @notice Setup for PT USDG/USDC Morpho Looper tests
/// @dev Inherits from Setup and overrides strategy deployment and token config
contract SetupPT is Setup {
    CurvePTExchange public exchange;

    // PT-USDG/USDC market
    Id public constant PT_MARKET_ID =
        Id.wrap(
            0x5cebfae10f5e88d33df2421923f3d9f32359429fda2f78edacc9b4fdb09b0553
        );

    // PT token (collateral)
    address public constant PT_TOKEN =
        0x9db38D74a0D29380899aD354121DfB521aDb0548; // PT-USDG-28MAY2026

    // Pendle market for PT swaps
    address public constant PENDLE_MARKET =
        0xC5b32dba5f29F8395fb9591E1a15f23A75214F33;

    address public constant PENDLE_TOKEN =
        0xe343167631d89B6Ffc58B88d6b7fB0228795491D;
    address public constant CURVE_USDG_USDC_POOL =
        0xc061caa073f3d95F80f8e5428d32D2d76F5e1622;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        _setTokenAddrs();

        // Set asset to USDC (same as base Setup)
        asset = ERC20(tokenAddrs["USDC"]);
        decimals = asset.decimals();

        // Fuzz amounts for 6 decimal token (USDC)
        minFuzzAmount = 100e6; // 100 USDC
        maxFuzzAmount = 50_000e6; // 50,000 USDC

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());
        _seedPtMorphoLiquidity(MORPHO_LIQUIDITY_SEED);

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(PT_TOKEN, "PT_TOKEN");
        vm.label(PENDLE_TOKEN, "PENDLE_TOKEN");
        vm.label(PENDLE_MARKET, "PENDLE_MARKET");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new CurvePTExchange(
            address(asset),
            PT_TOKEN,
            PENDLE_MARKET,
            PENDLE_TOKEN
        );

        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new MorphoLooper(
                    address(asset), // USDC
                    "PT USDG May 28 2026 Morpho Looper",
                    PT_TOKEN, // PT as collateral
                    MORPHO,
                    PT_MARKET_ID,
                    address(exchange),
                    management
                )
            )
        );
        exchange.transferGovernance(management);

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

        _setCurveRoute(address(asset), PENDLE_TOKEN, 1, 0);
        _setCurveRoute(PENDLE_TOKEN, address(asset), 0, 1);

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

    function _setCurveRoute(
        address from,
        address to,
        uint256 i,
        uint256 j
    ) internal {
        address[11] memory route;
        route[0] = from;
        route[1] = CURVE_USDG_USDC_POOL;
        route[2] = to;

        uint256[5][5] memory swapParams;
        swapParams[0] = [i, j, 1, 1, 2];

        address[5] memory pools;

        exchange.setCurveRoute(from, to, route, swapParams, pools);
    }

    function _seedPtMorphoLiquidity(uint256 amount) internal {
        MarketParams memory params = IMorpho(MORPHO).idToMarketParams(
            PT_MARKET_ID
        );
        deal(address(asset), address(this), amount);
        asset.approve(MORPHO, amount);
        IMorpho(MORPHO).supply(params, amount, 0, address(this), "");
    }
}
