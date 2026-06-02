// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {InfinifiPawnBrokerLooper} from "../../../pawnbroker/InfinifiPawnBrokerLooper.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {IInfiniFiGatewayV1} from "../../../interfaces/infinifi/IInfiniFiGatewayV1.sol";
import {IPawnBroker} from "pawn-broker/interfaces/IPawnBroker.sol";
import {PawnBrokerFactory} from "pawn-broker/PawnBrokerFactory.sol";

/// @notice Setup for the sIUSD/USDC pawn broker looper tests.
contract SetupPawnBrokerSIUSD is Setup {
    InfinifiPawnBrokerLooper public looper;
    IPawnBroker public pawnBroker;
    PawnBrokerFactory public pawnBrokerFactory;

    address public lender = makeAddr("pawn-broker-lender");
    address public user2 = makeAddr("pawn-broker-second-user");

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant SIUSD_ORACLE =
        0xd2cC46b9B2D761502eF933320ecf0268EC0dfa6d;

    uint256 public constant PAWN_BROKER_LIQUIDITY = 5_000_000e6;
    uint256 public constant PAWN_BROKER_LLTV = 915e15;
    uint256 public constant PAWN_BROKER_RATE = 400;
    uint256 public constant PAWN_BROKER_CALL_DURATION = 7 days;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        tokenAddrs["USDC"] = USDC;
        tokenAddrs["SIUSD"] = SIUSD;

        asset = ERC20(USDC);
        decimals = asset.decimals();

        maxFuzzAmount = 250_000e6;
        minFuzzAmount = 100e6;

        strategy = IStrategyInterface(setUpStrategy());
        factory = strategy.FACTORY();

        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(address(strategy), "strategy");
        vm.label(address(pawnBroker), "pawnBroker");
        vm.label(address(pawnBrokerFactory), "pawnBrokerFactory");
        vm.label(management, "management");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(lender, "pawnBrokerLender");
        vm.label(user2, "pawnBrokerSecondUser");
        vm.label(SIUSD, "sIUSD");
    }

    function setUpStrategy() public virtual override returns (address) {
        pawnBrokerFactory = new PawnBrokerFactory(
            management,
            performanceFeeRecipient,
            keeper,
            emergencyAdmin
        );

        address predictedLooper = vm.computeCreateAddress(
            address(this),
            vm.getNonce(address(this))
        );

        pawnBroker = IPawnBroker(
            pawnBrokerFactory.newPawnBroker(
                address(asset),
                "sIUSD Pawn Broker Market",
                predictedLooper,
                SIUSD,
                SIUSD_ORACLE,
                PAWN_BROKER_LLTV,
                PAWN_BROKER_RATE,
                PAWN_BROKER_CALL_DURATION
            )
        );

        vm.prank(management);
        pawnBroker.acceptManagement();

        looper = new InfinifiPawnBrokerLooper(
            address(asset),
            "sIUSD Pawn Broker Looper",
            address(pawnBroker),
            MORPHO,
            management
        );

        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        _strategy.setPendingManagement(management);

        vm.startPrank(management);
        _strategy.acceptManagement();
        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setEmergencyAdmin(emergencyAdmin);
        _strategy.setAllowed(user, true);
        _strategy.setAllowed(user2, true);
        _strategy.setMaxGasPriceToTend(type(uint256).max);
        _strategy.setProfitMaxUnlockTime(0);
        vm.stopPrank();

        _seedPawnBrokerLiquidity(PAWN_BROKER_LIQUIDITY);

        return address(_strategy);
    }

    function accrueYield(uint256 _amount) public virtual override {
        _amount = (_amount * 50) / 10_000;

        deal(address(asset), address(this), _amount);
        asset.approve(GATEWAY, _amount);
        IInfiniFiGatewayV1(GATEWAY).mintAndStake(address(strategy), _amount);

        vm.prank(management);
        strategy.manualSupplyCollateral(type(uint256).max);
    }

    function _seedPawnBrokerLiquidity(uint256 _amount) internal {
        vm.prank(management);
        pawnBroker.setAllowed(lender, true);

        airdrop(asset, lender, _amount);

        vm.startPrank(lender);
        asset.approve(address(pawnBroker), _amount);
        pawnBroker.deposit(_amount, lender);
        vm.stopPrank();
    }
}
