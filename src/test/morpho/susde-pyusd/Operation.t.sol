// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupSUSDePYUSD} from "./Setup.sol";
import {sUSDeMorphoLooper} from "../../../morpho/sUSDeMorphoLooper.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";

contract sUSDePYUSDMorphoOperationTest is SetupSUSDePYUSD, OperationTest {
    /// @dev Aave's sUSDe suite uses 15 BPS; the extra Curve hop here can leave
    ///      a touch more dust, but 15 BPS still holds within real fork spreads.
    uint256 internal constant SUSDE_UNWIND_DUST_BPS = 15;

    function setUp() public override(SetupSUSDePYUSD, OperationTest) {
        SetupSUSDePYUSD.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSUSDePYUSD, Setup)
        returns (address)
    {
        return SetupSUSDePYUSD.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSUSDePYUSD, Setup) {
        SetupSUSDePYUSD.accrueYield(_amount);
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

    /*//////////////////////////////////////////////////////////////
                        ROUTE / CONFIG SANITY
    //////////////////////////////////////////////////////////////*/

    function test_exchange_coreConfig() public view {
        assertEq(fluidExchange.base(), USDT, "!fluid base");

        MetaExchange.RouteStep[] memory forward = exchange.getRoute(
            PYUSD,
            SUSDE
        );
        assertEq(forward.length, 3, "!forward length");
        assertEq(forward[0].exchange, address(curveExchange), "!fwd ex 0");
        assertEq(forward[0].tokenTo, USDC, "!fwd token 0");
        assertEq(forward[1].exchange, address(fluidExchange), "!fwd ex 1");
        assertEq(forward[1].tokenTo, USDE, "!fwd token 1");
        assertEq(forward[2].exchange, address(erc4626Exchange), "!fwd ex 2");
        assertEq(forward[2].tokenTo, SUSDE, "!fwd token 2");

        MetaExchange.RouteStep[] memory unwind = exchange.getRoute(
            SUSDE,
            PYUSD
        );
        assertEq(unwind.length, 2, "!unwind length");
        assertEq(unwind[0].exchange, address(fluidExchange), "!unwind ex 0");
        assertEq(unwind[0].tokenTo, USDC, "!unwind token 0");
        assertEq(unwind[1].exchange, address(curveExchange), "!unwind ex 1");
        assertEq(unwind[1].tokenTo, PYUSD, "!unwind token 1");

        MetaExchange.RouteStep[] memory underlying = exchange.getRoute(
            USDE,
            PYUSD
        );
        assertEq(underlying.length, 2, "!underlying length");
        assertEq(
            underlying[0].exchange,
            address(fluidExchange),
            "!underlying ex 0"
        );
        assertEq(underlying[0].tokenTo, USDC, "!underlying token 0");
        assertEq(
            underlying[1].exchange,
            address(curveExchange),
            "!underlying ex 1"
        );
        assertEq(underlying[1].tokenTo, PYUSD, "!underlying token 1");
    }

    function test_setupStrategyOK() public override {
        OperationTest.test_setupStrategyOK();

        sUSDeMorphoLooper looper = sUSDeMorphoLooper(
            payable(address(strategy))
        );
        assertEq(looper.collateralToken(), SUSDE, "!collateralToken");
        assertEq(looper.pendingRedemptions(), 0, "!pendingRedemptions init");
    }

    function test_setExchange_onlyGovernance() public {
        sUSDeMorphoLooper looper = sUSDeMorphoLooper(
            payable(address(strategy))
        );
        MetaExchange newExchange = new MetaExchange(management);

        vm.prank(user);
        vm.expectRevert("!governance");
        looper.setExchange(address(newExchange));

        vm.prank(management);
        looper.setExchange(address(newExchange));
        assertEq(looper.exchange(), address(newExchange), "!exchange set");
    }

    /*//////////////////////////////////////////////////////////////
                        COOLDOWN STATE MACHINE
    //////////////////////////////////////////////////////////////*/

    function test_cooldown_functions_accessControl() public {
        sUSDeMorphoLooper looper = sUSDeMorphoLooper(
            payable(address(strategy))
        );

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

        sUSDeMorphoLooper looper = sUSDeMorphoLooper(
            payable(address(strategy))
        );

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

    function test_initiateCooldown_revertsWhileAlreadyPending() public {
        uint256 depositAmount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        vm.prank(keeper);
        strategy.tend();

        sUSDeMorphoLooper looper = sUSDeMorphoLooper(
            payable(address(strategy))
        );

        uint256 withdrawShares = looper.balanceOfCollateral() / 20;
        vm.prank(emergencyAdmin);
        looper.manualWithdrawCollateral(withdrawShares);

        uint256 looseShares = looper.balanceOfCollateralToken();
        vm.prank(management);
        looper.initiateCooldown(looseShares / 2);

        // Stage another loose chunk so the second call would otherwise succeed.
        vm.prank(emergencyAdmin);
        looper.manualWithdrawCollateral(withdrawShares);

        uint256 freshLoose = looper.balanceOfCollateralToken();
        vm.prank(management);
        vm.expectRevert("pending redemptions");
        looper.initiateCooldown(freshLoose);
    }

    function test_report_revertsWhilePendingRedemptionsOutstanding() public {
        uint256 depositAmount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        vm.prank(keeper);
        strategy.tend();

        sUSDeMorphoLooper looper = sUSDeMorphoLooper(
            payable(address(strategy))
        );

        uint256 withdrawShares = looper.balanceOfCollateral() / 20;
        vm.prank(emergencyAdmin);
        looper.manualWithdrawCollateral(withdrawShares);

        uint256 looseShares = looper.balanceOfCollateralToken();
        vm.prank(management);
        looper.initiateCooldown(looseShares);

        assertGt(looper.pendingRedemptions(), 0, "!pending precondition");

        vm.prank(keeper);
        vm.expectRevert("pending redemptions");
        strategy.report();
    }

    function test_zeroPendingRedemptions_clearsAccountingOnly() public {
        uint256 depositAmount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        vm.prank(keeper);
        strategy.tend();

        sUSDeMorphoLooper looper = sUSDeMorphoLooper(
            payable(address(strategy))
        );

        uint256 withdrawShares = looper.balanceOfCollateral() / 20;
        vm.prank(emergencyAdmin);
        looper.manualWithdrawCollateral(withdrawShares);

        uint256 looseShares = looper.balanceOfCollateralToken();
        vm.prank(management);
        looper.initiateCooldown(looseShares);
        assertGt(looper.pendingRedemptions(), 0, "!pending");

        vm.prank(management);
        looper.zeroPendingRedemptions();

        assertEq(looper.pendingRedemptions(), 0, "!pending cleared");

        vm.prank(management);
        strategy.setDoHealthCheck(false);
        vm.prank(keeper);
        strategy.report();
    }

    function test_convertUnderlyingToAsset_afterCooldown_unstakesAndSwapsToPYUSD()
        public
    {
        uint256 depositAmount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        vm.prank(keeper);
        strategy.tend();

        sUSDeMorphoLooper looper = sUSDeMorphoLooper(
            payable(address(strategy))
        );

        uint256 withdrawShares = looper.balanceOfCollateral() / 20;
        assertGt(withdrawShares, 0, "!withdrawShares");

        vm.prank(emergencyAdmin);
        looper.manualWithdrawCollateral(withdrawShares);

        uint256 looseShares = looper.balanceOfCollateralToken();
        vm.prank(management);
        uint256 cooldownAssets = looper.initiateCooldown(looseShares);

        assertGt(cooldownAssets, 0, "!cooldownAssets");
        assertEq(looper.pendingRedemptions(), cooldownAssets, "!pending");

        // Ethena cooldown is 7 days; pad to 8 to be safe across forks.
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
        assertEq(
            looper.balanceOfAsset(),
            assetBefore + amountOut,
            "!asset balance"
        );
    }
}
