// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupAavesUSDeUSDC} from "./Setup.sol";
import {sUSDeAaveLooper} from "../../../aave/sUSDeAaveLooper.sol";
import {sUSDeExchange} from "../../../periphery/sUSDeExchange.sol";

contract AavesUSDeUSDCOperationTest is SetupAavesUSDeUSDC, OperationTest {
    uint256 internal constant SUSDE_UNWIND_DUST_BPS = 5; // 0.05%

    function setUp() public override(SetupAavesUSDeUSDC, OperationTest) {
        SetupAavesUSDeUSDC.setUp();
    }

    function setUpStrategy()
        public
        override(SetupAavesUSDeUSDC, Setup)
        returns (address)
    {
        return SetupAavesUSDeUSDC.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupAavesUSDeUSDC, Setup) {
        SetupAavesUSDeUSDC.accrueYield(_amount);
    }

    function _maxUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure override returns (uint256) {
        uint256 relativeDust = collateralBeforeUnwind /
            (10_000 / SUSDE_UNWIND_DUST_BPS);
        return
            relativeDust > MIN_UNWIND_COLLATERAL_DUST
                ? relativeDust
                : MIN_UNWIND_COLLATERAL_DUST;
    }

    function test_exchange_coreConfig() public view {
        assertEq(exchange.ASSET(), USDC, "!asset");
        assertEq(exchange.COLLATERAL(), SUSDE, "!collateral");
        assertEq(exchange.UNDERLYING(), USDE, "!underlying");
        assertEq(exchange.base(), USDT, "!base");
        assertTrue(exchange.mint(), "!mint");
    }

    function test_setExchange_onlyGovernance() public {
        sUSDeAaveLooper looper = sUSDeAaveLooper(payable(address(strategy)));
        sUSDeExchange newExchange = new sUSDeExchange(WETH, USDT, USDC, SUSDE);

        vm.prank(user);
        vm.expectRevert("!governance");
        looper.setExchange(address(newExchange));

        vm.prank(management);
        looper.setExchange(address(newExchange));
    }

    function test_exchange_setMint_onlyManagement() public {
        vm.prank(user);
        vm.expectRevert("!management");
        exchange.setMint(false);

        vm.prank(management);
        exchange.setMint(false);
        assertFalse(exchange.mint(), "!mint");
    }

    function test_exchange_setFluidDex_onlyManagement() public {
        vm.prank(user);
        vm.expectRevert("!management");
        exchange.setFluidDex(USDC, USDT, FLUID_USDC_USDT);

        vm.prank(management);
        exchange.setFluidDex(USDC, USDT, FLUID_USDC_USDT);
    }

    function test_exchange_swap_onlyStrategy() public {
        vm.prank(user);
        vm.expectRevert("!strategy");
        exchange.exchange(USDC, SUSDE, 0, 0);
    }

    function test_cooldown_functions_onlyEmergencyAuthorized() public {
        sUSDeAaveLooper looper = sUSDeAaveLooper(payable(address(strategy)));

        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        looper.zeroPendingRedemptions();

        vm.prank(emergencyAdmin);
        looper.zeroPendingRedemptions();
    }

    function test_exchange_sweep_onlyGovernance() public {
        deal(USDC, address(exchange), 1_000e6);

        vm.prank(user);
        vm.expectRevert("!governance");
        exchange.sweep(USDC, type(uint256).max);

        uint256 beforeBal = ERC20(USDC).balanceOf(management);
        vm.prank(management);
        exchange.sweep(USDC, type(uint256).max);

        assertEq(ERC20(USDC).balanceOf(address(exchange)), 0, "!swept");
        assertEq(
            ERC20(USDC).balanceOf(management),
            beforeBal + 1_000e6,
            "!recv"
        );
    }
}
