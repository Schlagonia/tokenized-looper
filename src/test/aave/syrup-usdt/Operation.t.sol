// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupAaveSyrupUSDT} from "./Setup.sol";
import {SyrupUSDTAaveLooper} from "../../../aave/SyrupUSDTAaveLooper.sol";
import {SyrupExchange} from "../../../periphery/SyrupExchange.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Aave syrupUSDT operation tests
contract AaveSyrupUSDTOperationTest is SetupAaveSyrupUSDT, OperationTest {
    function setUp() public override(SetupAaveSyrupUSDT, OperationTest) {
        SetupAaveSyrupUSDT.setUp();
    }

    function setUpStrategy()
        public
        override(SetupAaveSyrupUSDT, Setup)
        returns (address)
    {
        return SetupAaveSyrupUSDT.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupAaveSyrupUSDT, Setup) {
        SetupAaveSyrupUSDT.accrueYield(_amount);
    }

    function test_zeroPendingRedemptions_onlyEmergencyAuthorized() public {
        SyrupUSDTAaveLooper looper = SyrupUSDTAaveLooper(
            payable(address(strategy))
        );

        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        looper.zeroPendingRedemptions();

        vm.prank(emergencyAdmin);
        looper.zeroPendingRedemptions();
    }

    function test_setExchange_onlyGovernance() public {
        SyrupUSDTAaveLooper looper = SyrupUSDTAaveLooper(
            payable(address(strategy))
        );
        SyrupExchange newExchange = new SyrupExchange(
            WETH,
            USDT,
            SYRUP_USDT,
            SYRUP_USDT_ROUTER
        );

        vm.prank(user);
        vm.expectRevert("!governance");
        looper.setExchange(address(newExchange));

        vm.prank(management);
        looper.setExchange(address(newExchange));
    }

    function test_exchange_setV4Pool_onlyManagement() public {
        SyrupExchange syrupExchange = exchange;

        vm.prank(user);
        vm.expectRevert("!management");
        syrupExchange.setV4Pool(USDT, SYRUP_USDT, bytes32(uint256(123)));

        vm.prank(management);
        syrupExchange.setV4Pool(USDT, SYRUP_USDT, bytes32(uint256(123)));
    }

    function test_exchange_setUniFees_onlyManagement() public {
        SyrupExchange syrupExchange = exchange;

        vm.prank(user);
        vm.expectRevert("!management");
        syrupExchange.setUniFees(USDT, SYRUP_USDT, 500);

        vm.prank(management);
        syrupExchange.setUniFees(USDT, SYRUP_USDT, 500);
    }

    function test_exchange_swap_isNotStrategyGated() public {
        SyrupExchange syrupExchange = exchange;

        vm.prank(user);
        uint256 amountOut = syrupExchange.exchange(USDT, SYRUP_USDT, 0, 0);
        assertEq(amountOut, 0, "!amountOut");
    }

    function test_exchange_setBase_onlyManagement() public {
        SyrupExchange syrupExchange = exchange;

        vm.prank(user);
        vm.expectRevert("!management");
        syrupExchange.setBase(WETH);

        vm.prank(management);
        syrupExchange.setBase(WETH);
    }

    function test_exchange_router_isConfiguredInConstructor() public view {
        SyrupExchange syrupExchange = exchange;
        assertEq(syrupExchange.SYRUP_ROUTER(), SYRUP_USDT_ROUTER, "!router");
    }

    function test_exchange_setMint_onlyManagement() public {
        SyrupExchange syrupExchange = exchange;

        vm.prank(user);
        vm.expectRevert("!management");
        syrupExchange.setMint(false);

        vm.prank(management);
        syrupExchange.setMint(false);

        assertFalse(syrupExchange.mint(), "!mint");
    }

    function test_exchange_directMint_worksWhenMapleAuthorized() public {
        uint256 amount = 10_000e6;

        _authorizeExchangeForSyrupDeposit();

        vm.prank(management);
        exchange.setMint(true);

        mintAndDepositIntoStrategy(strategy, user, amount);

        uint256 collateralBefore = ERC20(SYRUP_USDT).balanceOf(
            address(strategy)
        );
        vm.prank(address(strategy));
        exchange.exchange(USDT, SYRUP_USDT, amount, 0);
        uint256 collateralAfter = ERC20(SYRUP_USDT).balanceOf(
            address(strategy)
        );

        assertGt(collateralAfter, collateralBefore, "!collateral minted");
    }

    function test_exchange_sweep_onlyGovernance() public {
        SyrupExchange syrupExchange = exchange;
        address gov = management;

        deal(USDT, address(syrupExchange), 1_000e6);

        vm.prank(user);
        vm.expectRevert("!governance");
        syrupExchange.sweep(USDT, type(uint256).max);

        uint256 beforeBal = ERC20(USDT).balanceOf(gov);
        vm.prank(gov);
        syrupExchange.sweep(USDT, type(uint256).max);

        assertEq(ERC20(USDT).balanceOf(address(syrupExchange)), 0, "!swept");
        assertEq(ERC20(USDT).balanceOf(gov), beforeBal + 1_000e6, "!recv");
    }

    function test_exchange_sweep_ethNotSupported() public {
        SyrupExchange syrupExchange = exchange;
        address gov = management;

        vm.prank(gov);
        vm.expectRevert("!token");
        syrupExchange.sweep(address(0), type(uint256).max);
    }
}
