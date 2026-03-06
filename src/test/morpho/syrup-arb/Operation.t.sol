// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupSyrupUsdcArbMorpho} from "./Setup.sol";
import {SyrupMorphoLooper} from "../../../morpho/SyrupMorphoLooper.sol";

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
        SyrupMorphoLooper looper = SyrupMorphoLooper(
            payable(address(strategy))
        );

        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        looper.zeroPendingRedemptions();

        vm.prank(emergencyAdmin);
        looper.zeroPendingRedemptions();
    }
}
