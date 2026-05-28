// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IExchange} from "../../interfaces/IExchange.sol";
import {InventorySwapper} from "../../periphery/InventorySwapper.sol";
import {MetaExchange} from "../../periphery/MetaExchange.sol";

contract MockInventoryToken is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockMorphoStyleOracle {
    uint256 public price;

    function setPrice(uint256 _price) external {
        price = _price;
    }
}

contract MockInventoryStrategy {
    IExchange public exchange;

    constructor(address _exchange) {
        exchange = IExchange(_exchange);
    }

    function approveToken(
        address token,
        address spender,
        uint256 amount
    ) external {
        ERC20(token).approve(spender, amount);
    }

    function swap(
        address from,
        address to,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        return exchange.exchange(from, to, amountIn, minAmountOut);
    }
}

contract InventorySwapperTest is Test {
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    MockInventoryToken internal loanToken;
    MockInventoryToken internal collateralToken;
    MockInventoryToken internal otherToken;
    MockMorphoStyleOracle internal oracle;
    InventorySwapper internal swapper;

    address internal user = address(0xBEEF);

    function setUp() public {
        loanToken = new MockInventoryToken("Loan", "LOAN");
        collateralToken = new MockInventoryToken("Collateral", "COLL");
        otherToken = new MockInventoryToken("Other", "OTHER");
        oracle = new MockMorphoStyleOracle();
        oracle.setPrice(2e36); // 1 collateral = 2 loan tokens.

        swapper = new InventorySwapper(
            address(loanToken),
            address(collateralToken),
            address(oracle),
            100,
            address(this)
        );
        swapper.setAllowed(user, true);
    }

    function test_loanToCollateralUsesInventoryAndDiscount() public {
        uint256 amountIn = 100e18;
        uint256 expectedOut = 49.5e18;

        loanToken.mint(user, amountIn);
        collateralToken.mint(address(swapper), 1_000e18);
        swapper.setAllowedForwarder(user, true);

        vm.startPrank(user);
        loanToken.approve(address(swapper), amountIn);
        uint256 amountOut = swapper.exchangeWithContext(
            address(loanToken),
            address(collateralToken),
            amountIn,
            expectedOut,
            user
        );
        vm.stopPrank();

        assertEq(amountOut, expectedOut, "!amountOut");
        assertEq(loanToken.balanceOf(address(swapper)), amountIn, "!loan");
        assertEq(collateralToken.balanceOf(user), expectedOut, "!collateral");
        assertEq(
            collateralToken.balanceOf(address(swapper)),
            1_000e18 - expectedOut,
            "!inventory"
        );
    }

    function test_collateralToLoanUsesInventoryAndDiscount() public {
        uint256 amountIn = 10e18;
        uint256 expectedOut = 19.8e18;

        collateralToken.mint(user, amountIn);
        loanToken.mint(address(swapper), 100e18);
        swapper.setAllowedForwarder(user, true);

        vm.startPrank(user);
        collateralToken.approve(address(swapper), amountIn);
        uint256 amountOut = swapper.exchangeWithContext(
            address(collateralToken),
            address(loanToken),
            amountIn,
            expectedOut,
            user
        );
        vm.stopPrank();

        assertEq(amountOut, expectedOut, "!amountOut");
        assertEq(collateralToken.balanceOf(address(swapper)), amountIn, "!in");
        assertEq(loanToken.balanceOf(user), expectedOut, "!out");
    }

    function test_revertsForBadPairZeroPriceAndMissingInventory() public {
        loanToken.mint(user, 100e18);
        otherToken.mint(address(swapper), 100e18);
        swapper.setAllowedForwarder(user, true);

        vm.startPrank(user);
        loanToken.approve(address(swapper), 100e18);
        vm.expectRevert("!pair");
        swapper.exchangeWithContext(
            address(loanToken),
            address(otherToken),
            100e18,
            0,
            user
        );

        oracle.setPrice(0);
        vm.expectRevert("!price");
        swapper.exchangeWithContext(
            address(loanToken),
            address(collateralToken),
            100e18,
            0,
            user
        );

        oracle.setPrice(2e36);
        vm.expectRevert("!inventory");
        swapper.exchangeWithContext(
            address(loanToken),
            address(collateralToken),
            100e18,
            0,
            user
        );
        vm.stopPrank();
    }

    function test_governanceCanSetDiscount() public {
        vm.prank(user);
        vm.expectRevert("!governance");
        swapper.setDiscount(250);

        vm.expectRevert("discount");
        swapper.setDiscount(10_000);

        swapper.setDiscount(250);
        assertEq(swapper.discount(), 250, "!discount");
    }

    function test_governanceCanSetAllowedExchangeUsers() public {
        address blocked = address(0xCAFE);
        uint256 amountIn = 100e18;

        loanToken.mint(blocked, amountIn);
        collateralToken.mint(address(swapper), 1_000e18);
        swapper.setAllowedForwarder(blocked, true);

        vm.startPrank(blocked);
        loanToken.approve(address(swapper), amountIn);
        vm.expectRevert("!allowed");
        swapper.exchangeWithContext(
            address(loanToken),
            address(collateralToken),
            amountIn,
            0,
            blocked
        );
        vm.stopPrank();

        vm.prank(blocked);
        vm.expectRevert("!governance");
        swapper.setAllowed(blocked, true);

        vm.expectRevert("!account");
        swapper.setAllowed(address(0), true);

        swapper.setAllowed(blocked, true);
        assertTrue(swapper.allowed(blocked), "!allowed");

        vm.startPrank(blocked);
        uint256 amountOut = swapper.exchangeWithContext(
            address(loanToken),
            address(collateralToken),
            amountIn,
            0,
            blocked
        );
        vm.stopPrank();

        assertEq(amountOut, 49.5e18, "!amountOut");
    }

    function test_normalExchangeSelectorIsNotImplemented() public {
        loanToken.mint(user, 100e18);

        vm.startPrank(user);
        loanToken.approve(address(swapper), 100e18);
        vm.expectRevert();
        IExchange(address(swapper)).exchange(
            address(loanToken),
            address(collateralToken),
            100e18,
            0
        );
        vm.stopPrank();
    }

    function test_governanceCanSetAllowedForwarders() public {
        address forwarder = address(0xF0A);

        vm.prank(user);
        vm.expectRevert("!governance");
        swapper.setAllowedForwarder(forwarder, true);

        vm.expectRevert("!forwarder");
        swapper.setAllowedForwarder(address(0), true);

        swapper.setAllowedForwarder(forwarder, true);
        assertTrue(swapper.allowedForwarders(forwarder), "!forwarder");
    }

    function test_metaExchangeRouteUsesOriginalContextWhitelist() public {
        uint256 amountIn = 100e18;
        uint256 expectedOut = 49.5e18;

        MetaExchange meta = new MetaExchange(address(this));
        MockInventoryStrategy strategy = new MockInventoryStrategy(
            address(meta)
        );
        MockInventoryStrategy blocked = new MockInventoryStrategy(
            address(meta)
        );

        meta.setAllowedExchange(address(swapper), true);
        meta.setContextAwareExchange(address(swapper), true);
        swapper.setAllowedForwarder(address(meta), true);
        swapper.setAllowed(address(strategy), true);

        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](1);
        route[0] = MetaExchange.RouteStep({
            exchange: address(swapper),
            tokenFrom: address(loanToken),
            tokenTo: address(collateralToken)
        });
        meta.setRoute(address(loanToken), address(collateralToken), route);

        loanToken.mint(address(blocked), amountIn);
        loanToken.mint(address(strategy), amountIn);
        collateralToken.mint(address(swapper), 1_000e18);

        blocked.approveToken(address(loanToken), address(meta), amountIn);
        vm.expectRevert("!allowed");
        blocked.swap(address(loanToken), address(collateralToken), amountIn, 0);

        strategy.approveToken(address(loanToken), address(meta), amountIn);
        uint256 amountOut = strategy.swap(
            address(loanToken),
            address(collateralToken),
            amountIn,
            expectedOut
        );

        assertEq(amountOut, expectedOut, "!amountOut");
        assertEq(
            collateralToken.balanceOf(address(strategy)),
            expectedOut,
            "!collateral"
        );
    }

    function test_governanceCanSweepLooseBalances() public {
        loanToken.mint(address(swapper), 123e18);

        vm.prank(user);
        vm.expectRevert("!governance");
        swapper.sweep(address(loanToken), type(uint256).max);

        swapper.sweep(address(loanToken), type(uint256).max);

        assertEq(loanToken.balanceOf(address(this)), 123e18, "!swept");
        assertEq(loanToken.balanceOf(address(swapper)), 0, "!remaining");
    }
}
