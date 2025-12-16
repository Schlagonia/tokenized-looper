// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup} from "./Setup.sol";

abstract contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public virtual {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        // Collateral token should be set (specific token checked in derived tests if needed)
        assertTrue(
            strategy.collateralToken() != address(0),
            "!collateralToken"
        );

        // Check leverage params
        assertEq(strategy.targetLeverageRatio(), 3e18, "!targetLeverageRatio");
        assertEq(strategy.leverageBuffer(), 0.25e18, "!leverageBuffer");
    }

    function test_operation(uint256 _amount) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend (since _deployFunds is empty to prevent sandwich attacks)
        vm.prank(keeper);
        strategy.tend();

        logStrategyStatus("After deposit");

        assertGt(strategy.totalAssets(), 0, "!totalAssets");

        // Earn Interest
        accrueYield();

        // Report profit
        vm.prank(keeper);
        strategy.report();

        skip(strategy.profitMaxUnlockTime());

        logStrategyStatus("After profit max unlock time");

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore, "!final balance");
    }

    function test_profitableReport(uint256 _amount) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        skip(1 days);

        // simulate profit by airdropping USDC
        airdrop(asset, address(strategy), (_amount * 500) / 10_000);

        vm.prank(keeper);
        strategy.report();

        skip(strategy.profitMaxUnlockTime());

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGt(asset.balanceOf(user), _amount, "!profit not realized");
    }

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // After deposit with idle funds, tend should be triggered
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "tend should be triggered after deposit");

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        // After tend, should no longer need to tend (within buffer)
        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger, "tend should not be triggered after tending");
    }

    function test_leverageRatio(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Before deposit, leverage should be 1x (no position)
        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        assertEq(leverageBefore, 0, "!leverage before deposit");

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // After deposit but before tend, leverage should still be 1x (funds idle)
        uint256 leverageAfterDeposit = strategy.getCurrentLeverageRatio();
        assertEq(
            leverageAfterDeposit,
            0,
            "!leverage after deposit should be 0"
        );

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        // After tend, should be near target leverage
        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        uint256 targetLeverage = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();

        // Should be within buffer of target
        assertGe(leverageAfter, targetLeverage - buffer, "!leverage too low");
        assertLe(leverageAfter, targetLeverage + buffer, "!leverage too high");
    }

    function test_maxFlashloan() public {
        uint256 maxFL = strategy.maxFlashloan();
        assertGt(maxFL, 0, "!maxFlashloan should be > 0");
        console2.log("Max flashloan available:", maxFL);
    }

    function test_setLeverageParams() public {
        // Test setting leverage params
        vm.startPrank(management);

        // Set new target leverage to 2.5x with 0.15 buffer
        strategy.setLeverageParams(2.5e18, 0.15e18, 5e18);
        assertEq(strategy.targetLeverageRatio(), 2.5e18, "!new target");
        assertEq(strategy.leverageBuffer(), 0.15e18, "!new buffer");

        // Test bounds validation - leverage < 1x
        vm.expectRevert("leverage < 1x");
        strategy.setLeverageParams(0.5e18, 0.1e18, 5e18);

        // Test bounds validation - buffer too small
        vm.expectRevert("buffer too small");
        strategy.setLeverageParams(2e18, 0.001e18, 5e18);

        // Test bounds validation - exceeds LLTV
        // LLTV is ~91.5% which corresponds to max leverage of ~11.76x
        // Setting target + buffer above that should fail
        vm.expectRevert("exceeds LLTV");
        strategy.setLeverageParams(3e18, 1e18, 40e18); // 11x + 1x = 12x would exceed LLTV

        // Test bounds validation - max leverage < target + buffer
        vm.expectRevert("max leverage < target + buffer");
        strategy.setLeverageParams(2e18, 0.1e18, 1e18);

        vm.stopPrank();
    }

    function test_manualFullUnwind(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Deploy funds via tend
        vm.prank(keeper);
        strategy.tend();

        assertGt(strategy.totalAssets(), 0, "!totalAssets");
        assertGt(
            strategy.balanceOfCollateral(),
            0,
            "!collateral should be > 0 before unwind"
        );

        // Full unwind via flashloan
        vm.prank(management);
        strategy.manualFullUnwind();

        // Position should be closed
        assertEq(strategy.balanceOfCollateral(), 0, "!collateral should be 0");
        assertEq(strategy.balanceOfDebt(), 0, "!debt should be 0");
    }

    function test_manualPrimitives(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Airdrop asset to strategy for manual operations
        airdrop(asset, address(strategy), _amount);

        vm.prank(management);
        strategy.convertAssetToCollateral(type(uint256).max);

        // Manual supply collateral
        vm.prank(management);
        strategy.manualSupplyCollateral(type(uint256).max);

        uint256 collateral = strategy.balanceOfCollateral();
        assertGt(collateral, 0, "!collateral after supply");

        // Manual borrow
        uint256 borrowAmount = _amount / 2;
        vm.prank(management);
        strategy.manualBorrow(borrowAmount);

        uint256 debt = strategy.balanceOfDebt();
        assertGt(debt, 0, "!debt after borrow");

        // Manual repay
        vm.prank(management);
        strategy.manualRepay(type(uint256).max);

        uint256 debtAfterRepay = strategy.balanceOfDebt();
        assertLt(debtAfterRepay, debt, "!debt should decrease after repay");

        // Manual withdraw collateral
        vm.prank(management);
        strategy.manualWithdrawCollateral(collateral / 2);

        uint256 collateralAfter = strategy.balanceOfCollateral();
        assertLt(collateralAfter, collateral, "!collateral should decrease");
    }

    function test_leverageBoundsValidation() public {
        uint256 lltv = strategy.getLiquidateCollateralFactor();
        console2.log("LLTV:", lltv);

        // Calculate max safe leverage from LLTV
        // LTV = 1 - 1/leverage => leverage = 1 / (1 - LTV)
        uint256 maxSafeLeverage = (1e18 * 1e18) / (1e18 - lltv);
        console2.log("Max safe leverage:", maxSafeLeverage);

        // Should be able to set leverage up to but not exceeding the safe max
        vm.startPrank(management);

        // This should succeed - set to a moderate leverage
        strategy.setLeverageParams(3e18, 0.5e18, 5e18);
        assertEq(strategy.targetLeverageRatio(), 3e18);

        vm.stopPrank();
    }
}
