// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupAavesUSDeUSDC} from "./Setup.sol";
import {sUSDeAaveLooper} from "../../../aave/sUSDeAaveLooper.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";

contract AavesUSDeUSDCOperationTest is SetupAavesUSDeUSDC, OperationTest {
    uint256 internal constant SUSDE_UNWIND_DUST_BPS = 15; // 0.15%

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
        assertEq(fluidExchange.base(), USDT, "!base");

        MetaExchange.RouteStep[] memory forward = exchange.getRoute(
            USDC,
            SUSDE
        );
        assertEq(forward.length, 2, "!forward length");
        assertEq(forward[0].exchange, address(fluidExchange), "!forward ex 0");
        assertEq(forward[0].tokenTo, USDE, "!forward token 0");
        assertEq(
            forward[1].exchange,
            address(erc4626Exchange),
            "!forward ex 1"
        );
        assertEq(forward[1].tokenTo, SUSDE, "!forward token 1");

        MetaExchange.RouteStep[] memory unwind = exchange.getRoute(SUSDE, USDC);
        assertEq(unwind.length, 1, "!unwind length");
        assertEq(unwind[0].exchange, address(fluidExchange), "!unwind ex");
        assertEq(unwind[0].tokenTo, USDC, "!unwind token");

        MetaExchange.RouteStep[] memory underlying = exchange.getRoute(
            USDE,
            USDC
        );
        assertEq(underlying.length, 1, "!underlying length");
        assertEq(
            underlying[0].exchange,
            address(fluidExchange),
            "!underlying ex"
        );
        assertEq(underlying[0].tokenTo, USDC, "!underlying token");
    }

    function test_setExchange_onlyGovernance() public {
        sUSDeAaveLooper looper = sUSDeAaveLooper(payable(address(strategy)));
        MetaExchange newExchange = new MetaExchange(management);

        vm.prank(user);
        vm.expectRevert("!governance");
        looper.setExchange(address(newExchange));

        vm.prank(management);
        looper.setExchange(address(newExchange));
    }

    function test_exchange_setRoute_onlyGovernanceOrOperator() public {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](1);
        route[0] = MetaExchange.RouteStep({
            exchange: address(fluidExchange),
            tokenTo: USDE
        });

        vm.prank(user);
        vm.expectRevert("!operator");
        exchange.setRoute(USDC, USDE, route);

        vm.prank(management);
        exchange.setRoute(USDC, USDE, route);

        MetaExchange.RouteStep[] memory stored = exchange.getRoute(USDC, USDE);
        assertEq(stored.length, 1, "!route length");
        assertEq(stored[0].exchange, address(fluidExchange), "!route ex");
        assertEq(stored[0].tokenTo, USDE, "!route token");
    }

    function test_exchange_setFluidDex_onlyGovernanceOrOperator() public {
        vm.prank(user);
        vm.expectRevert("!operator");
        fluidExchange.setFluidDex(USDC, USDT, FLUID_USDC_USDT);

        vm.prank(management);
        fluidExchange.setFluidDex(USDC, USDT, FLUID_USDC_USDT);
    }

    function test_exchange_swap_isNotStrategyGated() public {
        vm.prank(user);
        uint256 amountOut = exchange.exchange(USDC, SUSDE, 0, 0);
        assertEq(amountOut, 0, "!amountOut");
    }

    function test_cooldown_functions_accessControl() public {
        sUSDeAaveLooper looper = sUSDeAaveLooper(payable(address(strategy)));

        vm.prank(user);
        vm.expectRevert("!management");
        looper.zeroPendingRedemptions();

        vm.prank(user);
        vm.expectRevert("!management");
        looper.initiateCooldown(0);

        vm.prank(user);
        vm.expectRevert("!keeper");
        looper.claimCooldown();

        vm.prank(user);
        vm.expectRevert("!keeper");
        looper.convertUnderlyingToAsset(0);

        vm.prank(management);
        looper.zeroPendingRedemptions();
    }

    function test_estimatedTotalAssets_countsPendingCooldownSharesInAssetTerms()
        public
    {
        uint256 depositAmount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        vm.prank(keeper);
        strategy.tend();

        sUSDeAaveLooper looper = sUSDeAaveLooper(payable(address(strategy)));

        uint256 withdrawShares = looper.balanceOfCollateral() / 20;
        assertGt(withdrawShares, 0, "!withdrawShares");

        vm.prank(emergencyAdmin);
        looper.manualWithdrawCollateral(withdrawShares);

        uint256 looseShares = looper.balanceOfCollateralToken();
        assertGt(looseShares, 0, "!looseShares");

        uint256 estimatedBeforeCooldown = looper.estimatedTotalAssets();

        vm.prank(management);
        uint256 cooldownAssets = looper.initiateCooldown(looseShares);

        assertEq(
            looper.pendingRedemptions(),
            cooldownAssets,
            "!pendingRedemptions"
        );
        assertEq(looper.balanceOfCollateralToken(), 0, "!looseShares cleared");

        uint256 estimatedAfterCooldown = looper.estimatedTotalAssets();
        (uint256 collateralValueAfter, uint256 debtAfter) = looper.position();
        uint256 estimatedWithoutPending = looper.balanceOfAsset() +
            collateralValueAfter -
            debtAfter;

        assertApproxEqAbs(
            estimatedAfterCooldown,
            estimatedBeforeCooldown,
            1,
            "!estimatedTotalAssets"
        );
        assertGt(
            estimatedAfterCooldown,
            estimatedWithoutPending,
            "!pendingRedemptions not counted"
        );
    }

    function test_convertUnderlyingToAsset_afterCooldown_clampsAndClaimsUSDeToUSDC()
        public
    {
        uint256 depositAmount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        vm.prank(keeper);
        strategy.tend();

        sUSDeAaveLooper looper = sUSDeAaveLooper(payable(address(strategy)));

        uint256 withdrawShares = looper.balanceOfCollateral() / 20;
        assertGt(withdrawShares, 0, "!withdrawShares");

        vm.prank(emergencyAdmin);
        looper.manualWithdrawCollateral(withdrawShares);

        uint256 looseShares = looper.balanceOfCollateralToken();
        assertGt(looseShares, 0, "!looseShares");

        vm.prank(management);
        uint256 cooldownAssets = looper.initiateCooldown(looseShares);

        assertGt(cooldownAssets, 0, "!cooldownAssets");
        assertEq(looper.pendingRedemptions(), cooldownAssets, "!pending");

        skip(8 days);

        vm.prank(keeper);
        looper.claimCooldown();

        uint256 underlyingBalance = looper.balanceOfUnderlying();
        uint256 assetBefore = looper.balanceOfAsset();

        assertGt(underlyingBalance, 0, "!underlying");
        assertEq(looper.pendingRedemptions(), 0, "!pending cleared");

        vm.prank(keeper);
        uint256 amountOut = looper.convertUnderlyingToAsset(type(uint256).max);

        assertGt(amountOut, 0, "!amountOut");
        assertEq(looper.balanceOfUnderlying(), 0, "!underlying cleared");
        assertEq(looper.balanceOfAsset(), assetBefore + amountOut, "!asset");
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
