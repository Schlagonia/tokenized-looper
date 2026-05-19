// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {InventorySwapper} from "../../periphery/InventorySwapper.sol";

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

    function test_loanToCollateralUsesInventoryAndSlippage() public {
        uint256 amountIn = 100e18;
        uint256 expectedOut = 49.5e18;

        loanToken.mint(user, amountIn);
        collateralToken.mint(address(swapper), 1_000e18);

        vm.startPrank(user);
        loanToken.approve(address(swapper), amountIn);
        uint256 amountOut = swapper.exchange(
            address(loanToken),
            address(collateralToken),
            amountIn,
            expectedOut
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

    function test_collateralToLoanUsesInventoryAndSlippage() public {
        uint256 amountIn = 10e18;
        uint256 expectedOut = 19.8e18;

        collateralToken.mint(user, amountIn);
        loanToken.mint(address(swapper), 100e18);

        vm.startPrank(user);
        collateralToken.approve(address(swapper), amountIn);
        uint256 amountOut = swapper.exchange(
            address(collateralToken),
            address(loanToken),
            amountIn,
            expectedOut
        );
        vm.stopPrank();

        assertEq(amountOut, expectedOut, "!amountOut");
        assertEq(collateralToken.balanceOf(address(swapper)), amountIn, "!in");
        assertEq(loanToken.balanceOf(user), expectedOut, "!out");
    }

    function test_revertsForBadPairZeroPriceAndMissingInventory() public {
        loanToken.mint(user, 100e18);
        otherToken.mint(address(swapper), 100e18);

        vm.startPrank(user);
        loanToken.approve(address(swapper), 100e18);
        vm.expectRevert("!pair");
        swapper.exchange(address(loanToken), address(otherToken), 100e18, 0);

        oracle.setPrice(0);
        vm.expectRevert("!price");
        swapper.exchange(
            address(loanToken),
            address(collateralToken),
            100e18,
            0
        );

        oracle.setPrice(2e36);
        vm.expectRevert("!inventory");
        swapper.exchange(
            address(loanToken),
            address(collateralToken),
            100e18,
            0
        );
        vm.stopPrank();
    }

    function test_governanceCanSetSlippage() public {
        vm.prank(user);
        vm.expectRevert("!governance");
        swapper.setSlippage(250);

        vm.expectRevert("slippage");
        swapper.setSlippage(10_000);

        swapper.setSlippage(250);
        assertEq(swapper.slippage(), 250, "!slippage");
    }

    function test_governanceCanSetAllowedExchangeUsers() public {
        address blocked = address(0xCAFE);
        uint256 amountIn = 100e18;

        loanToken.mint(blocked, amountIn);
        collateralToken.mint(address(swapper), 1_000e18);

        vm.startPrank(blocked);
        loanToken.approve(address(swapper), amountIn);
        vm.expectRevert("!allowed");
        swapper.exchange(
            address(loanToken),
            address(collateralToken),
            amountIn,
            0
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
        uint256 amountOut = swapper.exchange(
            address(loanToken),
            address(collateralToken),
            amountIn,
            0
        );
        vm.stopPrank();

        assertEq(amountOut, 49.5e18, "!amountOut");
    }

    function test_governanceCanPullLooseBalances() public {
        loanToken.mint(address(swapper), 123e18);

        vm.prank(user);
        vm.expectRevert("!governance");
        swapper.pullBalance(address(loanToken), type(uint256).max);

        swapper.pullBalance(address(loanToken), type(uint256).max);

        assertEq(loanToken.balanceOf(address(this)), 123e18, "!pulled");
        assertEq(loanToken.balanceOf(address(swapper)), 0, "!remaining");
    }
}
