// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ITaker} from "@periphery/interfaces/ITaker.sol";
import {ISwapAuction} from "../../interfaces/ISwapAuction.sol";
import {StrategySwapAuction} from "../../periphery/StrategySwapAuction.sol";

contract AuctionTestToken is ERC20 {
    uint8 internal immutable tokenDecimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }
}

contract MockStrategyAuctionTaker is ITaker {
    ISwapAuction public auction;

    address public lastFrom;
    address public lastSender;
    address public lastReceiver;
    uint256 public lastAmountTaken;
    uint256 public lastAmountNeeded;
    bytes public lastData;
    uint256 public callbackCount;

    function setAuction(address _auction) external {
        auction = ISwapAuction(_auction);
    }

    function kick(
        address _from,
        address _want,
        uint256 _amount,
        ISwapAuction.SwapDirection _direction,
        uint256 _startingPrice,
        uint256 _minimumPrice,
        uint256 _stepDecayRate
    ) external returns (uint256) {
        return
            auction.kick(
                _from,
                _want,
                _amount,
                _direction,
                _startingPrice,
                _minimumPrice,
                _stepDecayRate
            );
    }

    function forceKick(
        address _from,
        address _want,
        uint256 _amount,
        ISwapAuction.SwapDirection _direction,
        uint256 _startingPrice,
        uint256 _minimumPrice,
        uint256 _stepDecayRate
    ) external returns (uint256) {
        return
            auction.forceKick(
                _from,
                _want,
                _amount,
                _direction,
                _startingPrice,
                _minimumPrice,
                _stepDecayRate
            );
    }

    function settle(address _from) external {
        auction.settle(_from);
    }

    function auctionTakeCallback(
        address _from,
        address _sender,
        uint256 _amountTaken,
        uint256 _amountNeeded,
        bytes calldata _data
    ) external override {
        require(msg.sender == address(auction), "!auction");

        lastFrom = _from;
        lastSender = _sender;
        lastAmountTaken = _amountTaken;
        lastAmountNeeded = _amountNeeded;
        (lastReceiver, lastData) = abi.decode(_data, (address, bytes));
        callbackCount += 1;
    }
}

contract StrategySwapAuctionTest is Test {
    AuctionTestToken internal asset;
    AuctionTestToken internal collateral;
    StrategySwapAuction internal auction;
    MockStrategyAuctionTaker internal strategy;

    address internal taker = makeAddr("taker");
    address internal receiver = makeAddr("receiver");

    function setUp() public {
        asset = new AuctionTestToken("Asset", "AST", 6);
        collateral = new AuctionTestToken("Collateral", "COL", 18);

        auction = new StrategySwapAuction();
        strategy = new MockStrategyAuctionTaker();

        auction.setStrategy(address(strategy));
        strategy.setAuction(address(auction));
    }

    function test_setStrategy_onlyOnce() public {
        vm.expectRevert("!strategy");
        auction.setStrategy(address(strategy));
    }

    function test_kick_onlyStrategy() public {
        vm.expectRevert("!strategy");
        auction.kick(
            address(asset),
            address(collateral),
            100e6,
            ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL,
            2e18,
            18e17,
            10
        );
    }

    function test_kick_setsAuctionState() public {
        uint256 kicked = strategy.kick(
            address(asset),
            address(collateral),
            100e6,
            ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL,
            2e18,
            18e17,
            10
        );

        assertEq(kicked, 100e6, "!kicked");
        assertTrue(auction.isActive(address(asset)), "!active");
        assertEq(auction.available(address(asset)), 100e6, "!available");
        assertEq(auction.activeSellToken(), address(asset), "!sell");
        assertEq(auction.activeBuyToken(), address(collateral), "!buy");
        assertEq(
            uint256(auction.activeDirection()),
            uint256(ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL),
            "!direction"
        );

        ISwapAuction.AuctionInfo memory info = auction.activeAuction();
        assertEq(info.startingPrice, 2e18, "!startingPrice");
        assertEq(info.minimumPrice, 18e17, "!minimumPrice");
        assertEq(info.amountRemaining, 100e6, "!remaining");
    }

    function test_price_decaysAndExpires() public {
        strategy.kick(
            address(asset),
            address(collateral),
            100e6,
            ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL,
            2e18,
            19e17,
            100
        );

        uint256 initialPrice = auction.price(address(asset));
        assertEq(initialPrice, 2e18, "!initial");

        vm.warp(block.timestamp + 10);
        uint256 decayedPrice = auction.price(address(asset));
        assertLt(decayedPrice, initialPrice, "!decayed");
        assertGt(decayedPrice, 19e17, "!aboveFloor");

        vm.warp(block.timestamp + 30);
        assertEq(auction.price(address(asset)), 0, "!belowFloor");
        assertFalse(auction.isActive(address(asset)), "!active");

        strategy.forceKick(
            address(asset),
            address(collateral),
            100e6,
            ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL,
            2e18,
            19e17,
            10
        );

        vm.warp(block.timestamp + auction.auctionLength() + 1);
        assertEq(auction.price(address(asset)), 0, "!expired");
    }

    function test_take_partialFill_callsBackAndUpdatesRemaining() public {
        strategy.kick(
            address(asset),
            address(collateral),
            100e6,
            ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL,
            2e18,
            18e17,
            10
        );

        uint256 expectedNeeded = auction.getAmountNeeded(address(asset), 40e6);

        vm.prank(taker);
        uint256 amountTaken = auction.take(
            address(asset),
            40e6,
            receiver,
            hex"deadbeef"
        );

        assertEq(amountTaken, 40e6, "!taken");
        assertEq(strategy.lastFrom(), address(asset), "!from");
        assertEq(strategy.lastSender(), taker, "!sender");
        assertEq(strategy.lastReceiver(), receiver, "!receiver");
        assertEq(strategy.lastAmountTaken(), 40e6, "!amountTaken");
        assertEq(strategy.lastAmountNeeded(), expectedNeeded, "!amountNeeded");
        assertEq(strategy.lastData(), hex"deadbeef", "!data");
        assertEq(strategy.callbackCount(), 1, "!callbacks");
        assertEq(auction.available(address(asset)), 60e6, "!remaining");
        assertTrue(auction.isActive(address(asset)), "!active");
    }

    function test_take_fullFill_autoSettles() public {
        strategy.kick(
            address(collateral),
            address(asset),
            50e18,
            ISwapAuction.SwapDirection.COLLATERAL_TO_ASSET,
            9e17,
            8e17,
            10
        );

        vm.prank(taker);
        uint256 amountTaken = auction.take(address(collateral));

        assertEq(amountTaken, 50e18, "!taken");
        assertEq(auction.available(address(collateral)), 0, "!available");
        assertFalse(auction.isActive(address(collateral)), "!active");
        assertEq(auction.activeSellToken(), address(0), "!sellToken");
    }

    function test_forceKick_replacesInactiveAuction() public {
        strategy.kick(
            address(asset),
            address(collateral),
            100e6,
            ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL,
            2e18,
            19e17,
            100
        );

        vm.warp(block.timestamp + 30);
        assertFalse(auction.isActive(address(asset)), "!inactive");

        strategy.forceKick(
            address(collateral),
            address(asset),
            25e18,
            ISwapAuction.SwapDirection.COLLATERAL_TO_ASSET,
            9e17,
            8e17,
            10
        );

        assertEq(auction.activeSellToken(), address(collateral), "!sell");
        assertEq(auction.available(address(collateral)), 25e18, "!available");
    }
}
