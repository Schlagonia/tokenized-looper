// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {InfinifiMorphoLooper} from "../../InfinifiMorphoLooper.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {Id} from "../../interfaces/morpho/IMorpho.sol";
import {IInfiniFiGatewayV1} from "../../interfaces/infinifi/IInfiniFiGatewayV1.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is Test, IEvents {
    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    IStrategyInterface public strategy;

    mapping(string => address) public tokenAddrs;
    // Mainnet addresses
    address public constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    Id public constant MARKET_ID =
        Id.wrap(
            0xbbf7ce1b40d32d3e3048f5cf27eeaa6de8cb27b80194690aab191a63381d8c99
        );
    address public constant GATEWAY =
        0x3f04b65Ddbd87f9CE0A2e7Eb24d80e7fb87625b5;
    address public constant IUSD = 0x48f9e38f3070AD8945DFEae3FA70987722E3D89c;
    address public constant SIUSD = 0xDBDC1Ef57537E34680B898E1FEBD3D68c7389bCB;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from $0.01 of 1e6 stable coins up to 1 trillion of a 1e18 coin
    uint256 public maxFuzzAmount = 1e12; // up to 1,000,000 USDC
    uint256 public minFuzzAmount = 100e6; // 1 USDC (6 decimals)

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        _setTokenAddrs();

        // Set asset to USDC
        asset = ERC20(tokenAddrs["USDC"]);
        decimals = asset.decimals();

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

    function setUpStrategy() public virtual returns (address) {
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new InfinifiMorphoLooper(
                    address(asset),
                    "Morpho Looper",
                    SIUSD,
                    MORPHO,
                    MARKET_ID
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

    function depositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(
            address(_strategy)
        );
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function accrueYield(uint256 _amount) public virtual {
        skip(1 days);
        deal(address(asset), address(this), 1e6);
        asset.approve(address(GATEWAY), 1e6);
        IInfiniFiGatewayV1(GATEWAY).mintAndStake(address(this), 1e6);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function _setTokenAddrs() internal {
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    }

    function logStrategyStatus(string memory label) public view {
        console2.log("=== Strategy Status:", label, "===");
        console2.log("Total Assets:", strategy.totalAssets());
        (uint256 collateralValue, uint256 debt) = strategy.position();
        console2.log("Collateral:", collateralValue);
        console2.log("Debt:", debt);
        console2.log("Loose Asset:", strategy.balanceOfAsset());
        console2.log("Current LTV:", strategy.getCurrentLTV());
        console2.log("Current Leverage:", strategy.getCurrentLeverageRatio());
        console2.log("Max Flashloan:", strategy.maxFlashloan());
        console2.log("==============================");
    }
}
