// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupWOUSDMorpho} from "./Setup.sol";
import {OriginMorphoLooper} from "../../../morpho/OriginMorphoLooper.sol";
import {IOUSDVault} from "../../../interfaces/origin/IOUSDVault.sol";

contract WOUSDMorphoOperationTest is SetupWOUSDMorpho, OperationTest {
    function setUp() public override(SetupWOUSDMorpho, OperationTest) {
        SetupWOUSDMorpho.setUp();
    }

    function setUpStrategy()
        public
        override(SetupWOUSDMorpho, Setup)
        returns (address)
    {
        return SetupWOUSDMorpho.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupWOUSDMorpho, Setup) {
        SetupWOUSDMorpho.accrueYield(_amount);
    }

    function test_withdrawalFunctions_accessControl() public {
        OriginMorphoLooper looper = OriginMorphoLooper(address(strategy));

        vm.prank(user);
        vm.expectRevert("!management");
        looper.zeroPendingWithdrawals();

        vm.prank(user);
        vm.expectRevert("!management");
        looper.initiateWithdrawal(0);

        vm.prank(user);
        vm.expectRevert("!keeper");
        looper.claimWithdrawal(0);

        vm.prank(management);
        looper.zeroPendingWithdrawals();
    }

    function test_initiateWithdrawal_queuesLiveOriginWithdrawal() public {
        (
            OriginMorphoLooper looper,
            uint256 requestId,
            uint256 assets
        ) = _queueWithdrawal();

        IOUSDVault.WithdrawalRequest memory request = IOUSDVault(OUSD_VAULT)
            .withdrawalRequests(requestId);

        assertGt(assets, 0, "!assets");
        assertEq(looper.pendingWithdrawalAssets(), assets, "!pending");
        assertEq(looper.balanceOfCollateralToken(), 0, "!loose collateral");
        assertEq(looper.balanceOfUnderlying(), 0, "!loose underlying");
        assertEq(request.withdrawer, address(looper), "!withdrawer");
        assertEq(uint256(request.amount), assets, "!request amount");
        assertFalse(request.claimed, "!claimed");
    }

    function test_claimWithdrawal_clearsPendingOusdAccounting() public {
        (
            OriginMorphoLooper looper,
            uint256 requestId,
            uint256 assets
        ) = _queueWithdrawal();

        assertEq(looper.pendingWithdrawalAssets(), assets, "!pending");

        uint256 claimedUsdc = assets / 1e12;
        assertGt(claimedUsdc, 0, "!mock claimed");

        vm.mockCall(
            OUSD_VAULT,
            abi.encodeWithSelector(
                IOUSDVault.claimWithdrawal.selector,
                requestId
            ),
            abi.encode(claimedUsdc)
        );

        vm.prank(keeper);
        uint256 claimed = looper.claimWithdrawal(requestId);

        assertEq(claimed, claimedUsdc, "!claimed");
        assertEq(looper.pendingWithdrawalAssets(), 0, "!pending cleared");
    }

    function _queueWithdrawal()
        internal
        returns (OriginMorphoLooper looper, uint256 requestId, uint256 assets)
    {
        uint256 depositAmount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        vm.prank(keeper);
        strategy.tend();

        looper = OriginMorphoLooper(address(strategy));

        uint256 withdrawShares = looper.balanceOfCollateral() / 50;
        assertGt(withdrawShares, 0, "!withdrawShares");

        vm.prank(emergencyAdmin);
        looper.manualWithdrawCollateral(withdrawShares);

        uint256 looseShares = looper.balanceOfCollateralToken();
        assertGt(looseShares, 0, "!looseShares");

        vm.prank(management);
        (requestId, assets) = looper.initiateWithdrawal(looseShares);

        assertEq(ERC20(OUSD).balanceOf(address(looper)), 0, "!ousd");
    }
}
