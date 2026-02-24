// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupAaveSyrupUSDT} from "./Setup.sol";
import {SyrupUSDTAaveLooper} from "../../../aave/SyrupUSDTAaveLooper.sol";

/// @notice Aave syrupUSDT operation tests
contract AaveSyrupUSDTOperationTest is SetupAaveSyrupUSDT, OperationTest {
    function setUp() public override(SetupAaveSyrupUSDT, OperationTest) {
        SetupAaveSyrupUSDT.setUp();
    }

    function setUpStrategy()
        public
        override(SetupAaveSyrupUSDT, Setup)
        returns (address)
    {
        return SetupAaveSyrupUSDT.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupAaveSyrupUSDT, Setup) {
        SetupAaveSyrupUSDT.accrueYield(_amount);
    }

    function test_zeroPendingRedemptions_onlyEmergencyAuthorized() public {
        SyrupUSDTAaveLooper looper = SyrupUSDTAaveLooper(
            payable(address(strategy))
        );

        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        looper.zeroPendingRedemptions();

        vm.prank(emergencyAdmin);
        looper.zeroPendingRedemptions();
    }

    function test_setV4Pool_onlyManagement() public {
        SyrupUSDTAaveLooper looper = SyrupUSDTAaveLooper(
            payable(address(strategy))
        );

        vm.prank(user);
        vm.expectRevert("!management");
        looper.setV4Pool(USDT, SYRUP_USDT, bytes32(uint256(123)));
    }

    function test_setUniFees_onlyManagement() public {
        SyrupUSDTAaveLooper looper = SyrupUSDTAaveLooper(
            payable(address(strategy))
        );

        vm.prank(user);
        vm.expectRevert("!management");
        looper.setUniFees(USDT, SYRUP_USDT, 500);
    }
}
