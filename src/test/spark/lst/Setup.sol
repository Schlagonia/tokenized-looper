// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {LSTAaveLooper} from "../../../aave/LSTAaveLooper.sol";
import {WETHWstETHExchange} from "../../../periphery/WETHWstETHExchange.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";

/// @notice Setup for LST (wstETH/WETH) Spark Looper tests
/// @dev Spark exposes the same Aave V3 surface, so the looper can be reused as-is.
contract SetupSparkLST is Setup {
    WETHWstETHExchange public exchange;

    // SparkLend Ethereum mainnet core.
    address public constant SPARK_ADDRESSES_PROVIDER =
        0x02C3eA4e34C0cBd694D2adFa2c690EECbC1793eE;
    address public constant SPARK_POOL =
        0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address public constant MORPHO_FLASHLOAN_PROVIDER =
        0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // wstETH/WETH config
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Spark uses the ETH correlated eMode bucket for wstETH/WETH.
    uint8 public constant EMODE_CATEGORY_ID = 1;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        tokenAddrs["WETH"] = WETH;
        tokenAddrs["WSTETH"] = WSTETH;

        asset = ERC20(WETH);
        decimals = asset.decimals();

        maxFuzzAmount = 100e18;
        minFuzzAmount = 0.1e18;

        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(WSTETH, "WSTETH");
        vm.label(SPARK_ADDRESSES_PROVIDER, "SPARK_ADDRESSES_PROVIDER");
        vm.label(SPARK_POOL, "SPARK_POOL");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new WETHWstETHExchange();

        LSTAaveLooper looper = new LSTAaveLooper(
            address(asset),
            "LST Spark Looper",
            WSTETH,
            SPARK_ADDRESSES_PROVIDER,
            MORPHO_FLASHLOAN_PROVIDER,
            EMODE_CATEGORY_ID,
            address(exchange),
            management
        );
        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        exchange.setStrategy(address(_strategy));

        if (address(looper).balance > 0) {
            vm.deal(address(looper), 0);
        }

        _strategy.setPendingManagement(management);

        vm.startPrank(management);
        _strategy.acceptManagement();
        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setEmergencyAdmin(emergencyAdmin);
        _strategy.setAllowed(user, true);
        // Spark's oracle stack rejects long stale reads on a frozen fork.
        // Disabling profit locking keeps report/redeem tests on current oracle data.
        _strategy.setProfitMaxUnlockTime(0);
        _strategy.setMaxGasPriceToTend(type(uint256).max);
        vm.stopPrank();

        return address(_strategy);
    }

    function accrueYield(uint256) public virtual override {
        skip(1 days);
    }
}
