// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {MorphoLooper} from "../../../morpho/MorphoLooper.sol";
import {SUSDSUSDTExchange} from "../../../periphery/SUSDSUSDTExchange.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {Id} from "../../../interfaces/morpho/IMorpho.sol";

/// @notice Setup for sUSDS/USDT Morpho Looper tests
contract SetupSUSDSUSDT is Setup {
    SUSDSUSDTExchange public exchange;

    Id public constant SUSDS_USDT_MARKET_ID =
        Id.wrap(
            0x3274643db77a064abd3bc851de77556a4ad2e2f502f4f0c80845fa8f909ecf0b
        );
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        user = makeAddr("susds-usdt-user");

        tokenAddrs["USDT"] = USDT;
        tokenAddrs["USDC"] = USDC;
        tokenAddrs["USDS"] = USDS;
        tokenAddrs["SUSDS"] = SUSDS;

        asset = ERC20(USDT);
        decimals = asset.decimals();

        maxFuzzAmount = 1_000_000e6;
        minFuzzAmount = 100e6;

        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(SUSDS, "SUSDS");
        vm.label(USDS, "USDS");
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new SUSDSUSDTExchange();

        MorphoLooper looper = new MorphoLooper(
            address(asset),
            "sUSDS/USDT Morpho Looper",
            SUSDS,
            MORPHO,
            SUSDS_USDT_MARKET_ID,
            address(exchange),
            management
        );
        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        exchange.setStrategy(address(_strategy));

        _strategy.setPendingManagement(management);

        vm.startPrank(management);
        _strategy.acceptManagement();

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
        airdrop(asset, address(strategy), (_amount * 500) / 10_000);
    }
}
