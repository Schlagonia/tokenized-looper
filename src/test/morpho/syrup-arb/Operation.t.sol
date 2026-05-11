// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupSyrupUsdcArbMorpho} from "./Setup.sol";
import {MetaExchange} from "../../../periphery/exchanges/MetaExchange.sol";

contract SyrupUsdcArbMorphoOperationTest is
    SetupSyrupUsdcArbMorpho,
    OperationTest
{
    function setUp() public override(SetupSyrupUsdcArbMorpho, OperationTest) {
        SetupSyrupUsdcArbMorpho.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSyrupUsdcArbMorpho, Setup)
        returns (address)
    {
        return SetupSyrupUsdcArbMorpho.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSyrupUsdcArbMorpho, Setup) {
        SetupSyrupUsdcArbMorpho.accrueYield(_amount);
    }

    function _maxUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure override returns (uint256) {
        // Syrup share math and swaps can leave small residual collateral dust.
        uint256 relativeDust = collateralBeforeUnwind / 100; // 1%
        return
            relativeDust > MIN_UNWIND_COLLATERAL_DUST
                ? relativeDust
                : MIN_UNWIND_COLLATERAL_DUST;
    }

    function test_zeroPendingRedemptions_onlyEmergencyAuthorized() public {
        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        strategy.clearCooldown("");

        vm.prank(emergencyAdmin);
        strategy.clearCooldown("");
    }

    function test_exchange_routes_areConfiguredForArbSyrupMarket() public view {
        MetaExchange.RouteStep[] memory forward = exchange.getRoute(
            ARB_USDC,
            ARB_SYRUP_USDC
        );
        assertEq(forward.length, 1, "!forward length");
        assertEq(forward[0].exchange, address(fluidExchange), "!forward ex");
        assertEq(forward[0].tokenTo, ARB_SYRUP_USDC, "!forward token");

        MetaExchange.RouteStep[] memory reverse = exchange.getRoute(
            ARB_SYRUP_USDC,
            ARB_USDC
        );
        assertEq(reverse.length, 1, "!reverse length");
        assertEq(reverse[0].exchange, address(fluidExchange), "!reverse ex");
        assertEq(reverse[0].tokenTo, ARB_USDC, "!reverse token");
    }

    function test_exchange_routeDrivenTend_worksWithFluidSwap() public {
        uint256 amount = 10_000e6;

        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.tend();

        assertGt(strategy.balanceOfCollateral(), 0, "!collateral");
        assertGt(strategy.balanceOfDebt(), 0, "!debt");
    }
}
