// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {SyrupMorphoLooper} from "../../../morpho/SyrupMorphoLooper.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {Id} from "../../../interfaces/morpho/IMorpho.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";

/// @notice Setup for syrupUSDC/USDC Morpho looper tests on Arbitrum
contract SetupSyrupUsdcArbMorpho is Setup {
    MetaExchange public exchange;

    // Arbitrum Morpho deployment
    address public constant ARB_MORPHO =
        0x6c247b1F6182318877311737BaC0844bAa518F5e;

    // Provided market id (syrupUSDC/USDC on Arbitrum)
    Id public constant SYRUP_USDC_MARKET_ID =
        Id.wrap(
            0xf86f3edd6f16cd8211f4d206866dc4ecd41be6211063ac11f8508e1b7112ef40
        );

    // Market params for SYRUP_USDC_MARKET_ID:
    // loanToken = ARB_USDC, collateralToken = ARB_SYRUP_USDC
    address public constant ARB_USDC =
        0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant ARB_SYRUP_USDC =
        0x41CA7586cC1311807B4605fBB748a3B8862b42b5;

    // Arbitrum WETH
    address public constant ARB_WETH =
        0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    // Fluid DEX pool for syrupUSDC <-> USDC on Arbitrum
    address public constant ARB_FLUID_DEX_SYRUP_USDC_USDC =
        0xc800b0e15c40a1Ff0539218100c86F4c1BAC8D9C;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ARB_RPC_URL"));
        user = makeAddr("syrup-usdc-arb-user");

        tokenAddrs["USDC"] = ARB_USDC;
        tokenAddrs["SYRUP_USDC_ARB"] = ARB_SYRUP_USDC;

        asset = ERC20(ARB_USDC);
        decimals = asset.decimals();

        // Keep conservative while pool depth evolves. Small Arb positions can
        // unwind into sub-min Fluid trades on zero-amount delevers.
        maxFuzzAmount = 50_000e6;
        minFuzzAmount = 5_000e6;

        strategy = IStrategyInterface(setUpStrategy());
        factory = strategy.FACTORY();

        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(ARB_SYRUP_USDC, "ARB_SYRUP_USDC");
        vm.label(ARB_USDC, "ARB_USDC");
        vm.label(
            ARB_FLUID_DEX_SYRUP_USDC_USDC,
            "ARB_FLUID_DEX_SYRUP_USDC_USDC"
        );
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new MetaExchange(ARB_WETH);

        SyrupMorphoLooper looper = new SyrupMorphoLooper(
            address(asset),
            "syrupUSDC/USDC Arbitrum Morpho Looper",
            ARB_SYRUP_USDC,
            ARB_MORPHO,
            SYRUP_USDC_MARKET_ID,
            address(exchange),
            management
        );

        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        exchange.transferGovernance(management);

        _strategy.setPendingManagement(management);

        vm.prank(management);
        _strategy.acceptManagement();

        vm.startPrank(management);
        exchange.setFluidBase(address(asset));
        exchange.setFluidDex(
            address(asset),
            ARB_SYRUP_USDC,
            ARB_FLUID_DEX_SYRUP_USDC_USDC
        );
        _setRoutes();

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
        airdrop(asset, address(strategy), _amount / 30);
    }

    function _setRoutes() internal {
        MetaExchange.RouteStep[] memory forward = new MetaExchange.RouteStep[](
            1
        );
        forward[0] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.FLUID,
            tokenTo: ARB_SYRUP_USDC
        });
        exchange.setRoute(address(asset), ARB_SYRUP_USDC, forward);

        MetaExchange.RouteStep[] memory reverse = new MetaExchange.RouteStep[](
            1
        );
        reverse[0] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.FLUID,
            tokenTo: address(asset)
        });
        exchange.setRoute(ARB_SYRUP_USDC, address(asset), reverse);
    }
}
