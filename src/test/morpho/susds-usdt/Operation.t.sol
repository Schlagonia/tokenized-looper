// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupSUSDSUSDT} from "./Setup.sol";
import {SUSDSUSDTMorphoLooper} from "../../../morpho/SUSDSUSDTMorphoLooper.sol";

/// @notice sUSDS/USDT Operation tests - inherits all tests from OperationTest
contract SUSDSUSDTOperationTest is SetupSUSDSUSDT, OperationTest {
    function setUp() public override(SetupSUSDSUSDT, OperationTest) {
        SetupSUSDSUSDT.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSUSDSUSDT, Setup)
        returns (address)
    {
        return SetupSUSDSUSDT.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSUSDSUSDT, Setup) {
        SetupSUSDSUSDT.accrueYield(_amount);
    }

    function test_setSUSDSReferral() public {
        SUSDSUSDTMorphoLooper looper = SUSDSUSDTMorphoLooper(address(strategy));
        assertEq(looper.susdsReferral(), 0, "!default referral");

        vm.prank(management);
        looper.setSUSDSReferral(42);

        assertEq(looper.susdsReferral(), 42, "!set referral");
    }

    function test_setSUSDSReferral_onlyManagement() public {
        SUSDSUSDTMorphoLooper looper = SUSDSUSDTMorphoLooper(address(strategy));

        vm.prank(user);
        vm.expectRevert("!management");
        looper.setSUSDSReferral(7);
    }

    function test_tendWithSUSDSReferral(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        SUSDSUSDTMorphoLooper looper = SUSDSUSDTMorphoLooper(address(strategy));
        vm.prank(management);
        looper.setSUSDSReferral(7);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        assertGt(strategy.balanceOfCollateral(), 0, "!collateral");
    }
}
