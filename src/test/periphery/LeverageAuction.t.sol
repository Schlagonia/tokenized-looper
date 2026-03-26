// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITaker} from "@periphery/interfaces/ITaker.sol";

import {LeverageAuction} from "../../periphery/LeverageAuction.sol";

contract LeverageAuctionTestToken is ERC20 {
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

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockLeverageAuctionStrategy is ITaker {
    using SafeERC20 for ERC20;

    address public immutable fromToken;
    address public immutable wantToken;

    constructor(address _fromToken, address _wantToken) {
        fromToken = _fromToken;
        wantToken = _wantToken;
    }

    function auctionTakeCallback(
        address _from,
        address _sender,
        uint256 _amountTaken,
        uint256 _amountNeeded,
        bytes calldata _data
    ) external override {
        require(_from == fromToken, "!from");

        (address receiver, ) = abi.decode(_data, (address, bytes));
        ERC20(wantToken).safeTransferFrom(
            _sender,
            address(this),
            _amountNeeded
        );
        ERC20(fromToken).safeTransfer(receiver, _amountTaken);
    }
}

contract LeverageAuctionTest is Test {
    LeverageAuctionTestToken internal asset;
    LeverageAuctionTestToken internal collateral;
    MockLeverageAuctionStrategy internal strategy;
    LeverageAuction internal auction;

    address internal governance = makeAddr("governance");
    address internal taker = makeAddr("taker");
    address internal receiver = makeAddr("receiver");

    function setUp() public {
        asset = new LeverageAuctionTestToken("Asset", "AST", 18);
        collateral = new LeverageAuctionTestToken("Collateral", "COL", 18);
        strategy = new MockLeverageAuctionStrategy(
            address(asset),
            address(collateral)
        );
        auction = new LeverageAuction(
            address(asset),
            address(collateral),
            address(strategy),
            governance
        );

        asset.mint(address(strategy), 100e18);
        collateral.mint(taker, 1_000e18);
        vm.prank(taker);
        collateral.approve(address(strategy), type(uint256).max);
    }

    function test_kickAndTake_partialFillUpdatesRemaining() public {
        auction.kick(address(asset), 100e18, 110e18, 1e18, 100);
        assertEq(auction.available(address(asset)), 100e18, "!available");

        vm.prank(taker);
        uint256 amountTaken = auction.take(
            address(asset),
            40e18,
            receiver,
            abi.encode(uint256(1))
        );

        assertEq(amountTaken, 40e18, "!taken");
        assertEq(auction.available(address(asset)), 60e18, "!remaining");
        assertEq(asset.balanceOf(receiver), 40e18, "!receiver");
        assertEq(collateral.balanceOf(address(strategy)), 44e18, "!payment");
        assertEq(auction.kicked(address(asset)), block.timestamp, "!kicked");
    }

    function test_takeFullAmountSettlesAuction() public {
        auction.kick(address(asset), 100e18, 110e18, 1e18, 100);

        vm.prank(taker);
        auction.take(address(asset));

        assertEq(auction.available(address(asset)), 0, "!available");
        assertEq(auction.kicked(address(asset)), 0, "!settled");
        assertEq(asset.balanceOf(taker), 100e18, "!taker");
        assertEq(collateral.balanceOf(address(strategy)), 110e18, "!payment");
    }

    function test_priceFallsInactiveBelowFloor() public {
        auction.kick(address(asset), 100e18, 110e18, 1e18, 1_000);
        assertTrue(auction.isActive(address(asset)), "!active");

        skip(5 seconds);

        assertFalse(auction.isActive(address(asset)), "!inactive");
        assertEq(auction.available(address(asset)), 0, "!available");
    }
}
