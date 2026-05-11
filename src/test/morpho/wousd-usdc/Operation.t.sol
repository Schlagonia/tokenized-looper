// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupWOUSDMorpho} from "./Setup.sol";

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

    function _stageLooseWOUSD() internal returns (uint256 looseShares) {
        mintAndDepositIntoStrategy(strategy, user, _baseTestAmount());

        vm.prank(keeper);
        strategy.tend();

        uint256 withdrawShares = strategy.balanceOfCollateral() / 20;
        assertGt(withdrawShares, 0, "!withdrawShares");

        vm.prank(emergencyAdmin);
        strategy.manualWithdrawCollateral(withdrawShares);

        looseShares = strategy.balanceOfCollateralToken();
        assertGt(looseShares, 0, "!looseShares");
    }

    function test_originCooldown_initiateTracksPendingAndBlocksReports()
        public
    {
        uint256 looseShares = _stageLooseWOUSD();
        uint256 totalBefore = strategy.estimatedTotalAssets();

        vm.prank(emergencyAdmin);
        (uint256 requestId, uint256 underlyingAmount) = abi.decode(
            strategy.initiateCooldown(looseShares, ""),
            (uint256, uint256)
        );

        assertGt(requestId, 0, "!requestId");
        assertGt(underlyingAmount, 0, "!underlyingAmount");
        assertGt(cooldownAdapter.pendingWithdrawalAssets(), 0, "!pending");
        assertEq(strategy.balanceOfCollateralToken(), 0, "!loose cleared");
        assertApproxEqRel(
            strategy.estimatedTotalAssets(),
            totalBefore,
            0.001e18,
            "!eta"
        );

        vm.prank(keeper);
        vm.expectRevert("pending cooldown");
        strategy.report();
    }

    function test_originCooldown_clearAllowsReports() public {
        uint256 looseShares = _stageLooseWOUSD();

        vm.prank(emergencyAdmin);
        strategy.initiateCooldown(looseShares, "");
        assertGt(cooldownAdapter.pendingWithdrawalAssets(), 0, "!pending");

        vm.prank(emergencyAdmin);
        strategy.clearCooldown("");
        assertEq(
            cooldownAdapter.pendingWithdrawalAssets(),
            0,
            "!pending cleared"
        );

        vm.prank(management);
        strategy.setDoHealthCheck(false);
        vm.prank(keeper);
        strategy.report();
    }
}
