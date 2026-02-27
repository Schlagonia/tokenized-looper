// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupSyrupMorpho} from "./Setup.sol";
import {SyrupMorphoLooper} from "../../../morpho/SyrupMorphoLooper.sol";

/// @notice syrup/USDC Morpho operation tests
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
}
