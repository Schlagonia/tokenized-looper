// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupSyrupMorpho} from "./Setup.sol";
import {SyrupMorphoLooper} from "../../../morpho/SyrupMorphoLooper.sol";
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
