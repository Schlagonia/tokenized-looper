// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {MorphoLooper} from "../../../morpho/MorphoLooper.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {IMorpho, Id, MarketParams} from "../../../interfaces/morpho/IMorpho.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";
import {PendleExchange} from "../../../periphery/PendleExchange.sol";

contract TestMorphoLooper is MorphoLooper {
    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId,
        address _exchange,
        address _governance
    )
        MorphoLooper(
            _asset,
            _name,
            _collateralToken,
            _morpho,
            _marketId,
            _exchange,
            _governance
        )
    {}

    function setSlippageForTests(uint64 _slippage) external {
        slippage = _slippage;
    }
}

/// @notice Setup for PT stcUSD/USDC Morpho Looper tests
/// @dev Inherits from Setup and overrides strategy deployment and token config
contract SetupPT is Setup {
    MetaExchange public exchange;
    PendleExchange public pendleExchange;

    uint64 internal constant PT_TEST_SLIPPAGE = 500;

    // PT-stcUSD/USDC market
    Id public constant PT_MARKET_ID =
        Id.wrap(
            0x2fb3713487c7812e7309935b034f40228841666f6b048faf31fd2110ae674f20
        );

    // PT token (collateral)
    address public constant PT_TOKEN =
        0x2d3C279E5FcDF5b793c0a75ed90738D7369B0b83; // PT-stcUSD-23JUL2026

    // Pendle market for PT swaps
    address public constant PENDLE_MARKET =
        0xaC24A6f0068d9701EAEa76AB0B418021017F8D59;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        _setTokenAddrs();

        // Set asset to USDC (same as base Setup)
        asset = ERC20(tokenAddrs["USDC"]);
        decimals = asset.decimals();

        // Fuzz amounts for 6 decimal token (USDC)
        minFuzzAmount = 100e6; // 100 USDC
        maxFuzzAmount = 25_000e6; // 25,000 USDC

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
        vm.label(PENDLE_MARKET, "PENDLE_MARKET");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new MetaExchange(management);
        pendleExchange = new PendleExchange(PENDLE_ROUTER, management);

        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new TestMorphoLooper(
                    address(asset), // USDC
                    "PT stcUSD Jul 23 2026 Morpho Looper",
                    PT_TOKEN, // PT as collateral
                    MORPHO,
                    PT_MARKET_ID,
                    address(exchange),
                    management
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

        // Pendle reverts tiny PT swaps when fee math rounds to zero.
        _strategy.setMinAmountToBorrow(50_000);
        TestMorphoLooper(address(_strategy)).setSlippageForTests(
            PT_TEST_SLIPPAGE
        );

        // Set profit max unlock to 0 so oracle doesn't revert after time skip
        _strategy.setProfitMaxUnlockTime(0);

        pendleExchange.setPendleMarket(PT_TOKEN, PENDLE_MARKET);
        pendleExchange.setGuessMaxMultiplier(2);
        exchange.setAllowedExchange(address(pendleExchange), true);
        _setRoutes();

        vm.stopPrank();

        return address(_strategy);
    }

    /// @notice Override accrueYield - airdrop profit instead of skipping time
    /// @dev PT price/oracle paths can get grumpy after large time skips, so we simulate yield via airdrop
    function accrueYield(uint256 _amount) public virtual override {
        // Don't skip time. Pendle/Morpho pricing starts throwing chairs when the clock jumps.
        // Simulate yield by airdropping some profit instead.
        airdrop(asset, address(strategy), (_amount * 800) / 10_000);
    }

    function _setRoutes() internal {
        MetaExchange.RouteStep[] memory forward = new MetaExchange.RouteStep[](
            1
        );
        forward[0] = MetaExchange.RouteStep({
            exchange: address(pendleExchange),
            tokenFrom: address(asset),
            tokenTo: PT_TOKEN
        });
        exchange.setRoute(address(asset), PT_TOKEN, forward);

        MetaExchange.RouteStep[] memory reverse = new MetaExchange.RouteStep[](
            1
        );
        reverse[0] = MetaExchange.RouteStep({
            exchange: address(pendleExchange),
            tokenFrom: PT_TOKEN,
            tokenTo: address(asset)
        });
        exchange.setRoute(PT_TOKEN, address(asset), reverse);
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
