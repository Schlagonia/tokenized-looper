// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../base/Setup.sol";
import {LSTMorphoLooper} from "../../LSTMorphoLooper.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {Id} from "../../interfaces/morpho/IMorpho.sol";

/// @notice Setup for LST (wstETH/WETH) Morpho Looper tests
/// @dev Inherits from Setup and overrides strategy deployment and token config
contract SetupLST is Setup {
    // wstETH/WETH market
    Id public constant LST_MARKET_ID =
        Id.wrap(
            0xb8fc70e82bc5bb53e773626fcc6a23f7eefa036918d7ef216ecfb1950a94a85e
        );
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

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
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public virtual override returns (address) {
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new LSTMorphoLooper(
                    address(asset),
                    "LST Morpho Looper",
                    WSTETH,
                    MORPHO,
                    LST_MARKET_ID,
                    ROUTER
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

        // Set higher slippage tolerance for testing (25% for now - investigate swap pricing)
        //_strategy.setSlippage(2500);

        vm.stopPrank();

        return address(_strategy);
    }

    /// @notice Override accrueYield - for LST just skip time
    function accrueYield(uint256 _amount) public virtual override {
        skip(1 days);
        airdrop(asset, address(strategy), _amount * 500 / 10_000);

    }
}
