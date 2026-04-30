// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupSyrupMorpho} from "./Setup.sol";
import {SyrupMorphoLooper} from "../../../morpho/SyrupMorphoLooper.sol";
import {ISyrupPool} from "../../../interfaces/syrup/ISyrupPool.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";

/// @notice syrup/PYUSD Morpho operation tests
contract SyrupMorphoOperationTest is SetupSyrupMorpho, OperationTest {
    function setUp() public override(SetupSyrupMorpho, OperationTest) {
        SetupSyrupMorpho.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSyrupMorpho, Setup)
        returns (address)
    {
        return SetupSyrupMorpho.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSyrupMorpho, Setup) {
        SetupSyrupMorpho.accrueYield(_amount);
    }

    function _maxUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure override returns (uint256) {
        // Syrup unwinds can leave slightly more residual share dust.
        uint256 relativeDust = (collateralBeforeUnwind * 5) / 10_000; // 5 bps
        return
            relativeDust > MIN_UNWIND_COLLATERAL_DUST
                ? relativeDust
                : MIN_UNWIND_COLLATERAL_DUST;
    }

    function test_zeroPendingRedemptions_onlyEmergencyAuthorized() public {
        SyrupMorphoLooper looper = SyrupMorphoLooper(
            payable(address(strategy))
        );

        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        looper.zeroPendingRedemptions();

        vm.prank(emergencyAdmin);
        looper.zeroPendingRedemptions();
    }

    /*//////////////////////////////////////////////////////////////
                DIRECT REDEMPTION TESTS (REAL MAPLE FORK)
    //////////////////////////////////////////////////////////////*/

    /// @dev Build a position then withdraw a slice of collateral so that
    ///      `balanceOfCollateralToken()` is the strategy's loose syrupUSDC.
    function _stageLooseSyrupShares(
        uint256 amount,
        uint256 fractionBps
    ) internal returns (uint256 loose) {
        mintAndDepositIntoStrategy(strategy, user, amount);
        vm.prank(keeper);
        strategy.tend();

        uint256 totalCollateral = strategy.balanceOfCollateral();
        uint256 toWithdraw = (totalCollateral * fractionBps) / MAX_BPS;

        vm.prank(management);
        strategy.manualWithdrawCollateral(toWithdraw);

        loose = strategy.balanceOfCollateralToken();
    }

    function test_initiateDirectRedemption_onlyEmergencyAuthorized() public {
        SyrupMorphoLooper looper = SyrupMorphoLooper(
            payable(address(strategy))
        );

        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        looper.initiateDirectRedemption(1);
    }

    function test_initiateDirectRedemption_revertsWithoutShares() public {
        SyrupMorphoLooper looper = SyrupMorphoLooper(
            payable(address(strategy))
        );

        // No loose shares + clamp to balance => 0 => "!shares"
        assertEq(looper.balanceOfCollateralToken(), 0, "!precondition");

        vm.prank(emergencyAdmin);
        vm.expectRevert("!shares");
        looper.initiateDirectRedemption(type(uint256).max);
    }

    function test_initiateDirectRedemption_queuesRealSharesOnSyrupPool()
        public
    {
        uint256 loose = _stageLooseSyrupShares(10_000e6, 500); // 5%
        assertGt(loose, 0, "!loose");

        SyrupMorphoLooper looper = SyrupMorphoLooper(
            payable(address(strategy))
        );
        assertEq(looper.pendingRedemptionShares(), 0, "!initial pending");

        uint256 strategyBalanceBefore = ERC20(SYRUP_USDC).balanceOf(
            address(strategy)
        );

        vm.prank(emergencyAdmin);
        uint256 exitShares = looper.initiateDirectRedemption(loose);

        assertGt(exitShares, 0, "!exitShares");
        assertEq(
            looper.pendingRedemptionShares(),
            exitShares,
            "!pending tracked"
        );
        // Maple withdrawal manager sweeps the requested shares out of the
        // strategy when the request is enqueued.
        assertLt(
            ERC20(SYRUP_USDC).balanceOf(address(strategy)),
            strategyBalanceBefore,
            "!shares moved out"
        );
    }

    function test_cancelDirectRedemption_onlyEmergencyAuthorized() public {
        SyrupMorphoLooper looper = SyrupMorphoLooper(
            payable(address(strategy))
        );

        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        looper.cancelDirectRedemption(1);
    }

    function test_cancelDirectRedemption_revertsWithoutPending() public {
        SyrupMorphoLooper looper = SyrupMorphoLooper(
            payable(address(strategy))
        );
        assertEq(looper.pendingRedemptionShares(), 0, "!precondition");

        vm.prank(emergencyAdmin);
        vm.expectRevert("!shares");
        looper.cancelDirectRedemption(type(uint256).max);
    }

    function test_cancelDirectRedemption_clearsPendingAndReturnsShares()
        public
    {
        uint256 loose = _stageLooseSyrupShares(10_000e6, 500); // 5%

        SyrupMorphoLooper looper = SyrupMorphoLooper(
            payable(address(strategy))
        );
        vm.prank(emergencyAdmin);
        uint256 exitShares = looper.initiateDirectRedemption(loose);
        assertEq(looper.pendingRedemptionShares(), exitShares, "!queued");

        uint256 strategyBalanceMid = ERC20(SYRUP_USDC).balanceOf(
            address(strategy)
        );

        vm.prank(emergencyAdmin);
        uint256 removed = looper.cancelDirectRedemption(type(uint256).max);

        assertGt(removed, 0, "!removed");
        assertEq(looper.pendingRedemptionShares(), 0, "!pending cleared");
        // Cancelled shares come back to the strategy.
        assertGt(
            ERC20(SYRUP_USDC).balanceOf(address(strategy)),
            strategyBalanceMid,
            "!shares returned"
        );
    }

    function test_report_revertsWhilePendingRedemptionsOutstanding() public {
        uint256 loose = _stageLooseSyrupShares(10_000e6, 500); // 5%

        SyrupMorphoLooper looper = SyrupMorphoLooper(
            payable(address(strategy))
        );
        vm.prank(emergencyAdmin);
        looper.initiateDirectRedemption(loose);

        assertGt(looper.pendingRedemptionShares(), 0, "!pending");

        vm.prank(keeper);
        vm.expectRevert("pending redemptions");
        strategy.report();
    }

    function test_estimatedTotalAssets_includesPendingRedemption() public {
        // Take a snapshot pre-request, including the loose shares value.
        uint256 loose = _stageLooseSyrupShares(10_000e6, 500); // 5%
        uint256 totalBefore = strategy.estimatedTotalAssets();

        SyrupMorphoLooper looper = SyrupMorphoLooper(
            payable(address(strategy))
        );
        vm.prank(emergencyAdmin);
        looper.initiateDirectRedemption(loose);

        // After request, the strategy no longer holds the loose shares but
        // estimatedTotalAssets() should still include them via the pending
        // redemption value, so total assets must remain ~unchanged.
        uint256 totalAfter = strategy.estimatedTotalAssets();
        assertApproxEqRel(
            totalAfter,
            totalBefore,
            0.001e18,
            "!totalAssets should track pending"
        );
    }

    function test_zeroPendingRedemptions_clearsAccountingOnly() public {
        uint256 loose = _stageLooseSyrupShares(10_000e6, 500); // 5%

        SyrupMorphoLooper looper = SyrupMorphoLooper(
            payable(address(strategy))
        );
        vm.prank(emergencyAdmin);
        looper.initiateDirectRedemption(loose);
        assertGt(looper.pendingRedemptionShares(), 0, "!pending");

        // zeroPendingRedemptions must not call into Maple; it is purely a
        // bookkeeping reset to be used after Maple has filled the request.
        vm.prank(emergencyAdmin);
        looper.zeroPendingRedemptions();

        assertEq(looper.pendingRedemptionShares(), 0, "!pending cleared");

        // With pending zeroed, report() must succeed again.
        vm.prank(management);
        strategy.setDoHealthCheck(false);
        vm.prank(keeper);
        strategy.report();
    }

    function test_exchange_setSyrupDepositConfig_onlyManagement() public {
        vm.prank(user);
        vm.expectRevert("!operator");
        syrupExchange.setSyrupDepositConfig(
            SYRUP_USDC,
            SYRUP_USDC_ROUTER,
            bytes32("Maple")
        );

        vm.prank(management);
        syrupExchange.setSyrupDepositConfig(
            SYRUP_USDC,
            SYRUP_USDC_ROUTER,
            bytes32("Maple")
        );

        (address router, bytes32 depositData) = syrupExchange
            .syrupDepositConfigs(SYRUP_USDC);
        assertEq(router, SYRUP_USDC_ROUTER, "!router");
        assertEq(depositData, bytes32("Maple"), "!depositData");
    }

    function test_exchange_routes_areConfiguredForPyusdMarket() public view {
        MetaExchange.RouteStep[] memory forward = exchange.getRoute(
            PYUSD,
            SYRUP_USDC
        );
        assertEq(forward.length, 2, "!forward length");
        assertEq(forward[0].exchange, address(curveExchange), "!forward ex 0");
        assertEq(forward[0].tokenTo, USDC, "!forward token 0");
        assertEq(forward[1].exchange, address(syrupExchange), "!forward ex 1");
        assertEq(forward[1].tokenTo, SYRUP_USDC, "!forward token 1");

        MetaExchange.RouteStep[] memory reverse = exchange.getRoute(
            SYRUP_USDC,
            PYUSD
        );
        assertEq(reverse.length, 2, "!reverse length");
        assertEq(reverse[0].exchange, address(uniExchange), "!reverse ex 0");
        assertEq(reverse[0].tokenTo, USDC, "!reverse token 0");
        assertEq(reverse[1].exchange, address(curveExchange), "!reverse ex 1");
        assertEq(reverse[1].tokenTo, PYUSD, "!reverse token 1");
    }

    function test_exchange_routeDrivenTend_worksWithSyrupDeposit() public {
        uint256 amount = 10_000e6;

        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.tend();

        assertGt(strategy.balanceOfCollateral(), 0, "!collateral");
        assertGt(strategy.balanceOfDebt(), 0, "!debt");
    }
}
