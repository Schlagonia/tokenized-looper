// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup} from "../../base/Setup.sol";
import {SetupAaveLST} from "./Setup.sol";
import {LSTAaveLooper} from "../../../aave/LSTAaveLooper.sol";
import {IQueue, IwstETH} from "../../../interfaces/IStethInterfaces.sol";

interface IQueueExtended is IQueue {
    struct WithdrawalRequestStatus {
        uint256 amountOfStETH;
        uint256 amountOfShares;
        address owner;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }

    function getWithdrawalStatus(
        uint256[] calldata _requestIds
    ) external view returns (WithdrawalRequestStatus[] memory statuses);

    function getLastCheckpointIndex() external view returns (uint256);

    function findCheckpointHints(
        uint256[] calldata _requestIds,
        uint256 _firstIndex,
        uint256 _lastIndex
    ) external view returns (uint256[] memory hintIds);

    function claimWithdrawals(
        uint256[] calldata _requestIds,
        uint256[] calldata _hints
    ) external;
}

/// @notice Mock withdrawal queue that sends ETH on claim
contract MockWithdrawalQueue {
    function claimWithdrawal(uint256) external {
        // Send all ETH held by this mock to the caller
        payable(msg.sender).transfer(address(this).balance);
    }
}

/// @notice Tests for LSTAaveLooper manual LST withdrawal functions
contract LSTWithdrawalTest is SetupAaveLST {
    LSTAaveLooper public lstLooper;
    IQueueExtended public withdrawalQueue;
    IwstETH public wstETH;

    address public constant WITHDRAWAL_QUEUE_ADDR =
        0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    function setUp() public override {
        super.setUp();
        lstLooper = LSTAaveLooper(payable(address(strategy)));
        withdrawalQueue = IQueueExtended(WITHDRAWAL_QUEUE_ADDR);
        wstETH = IwstETH(WSTETH);

        vm.label(WITHDRAWAL_QUEUE_ADDR, "WithdrawalQueue");
    }

    /// @notice Helper to setup a mock withdrawal queue that sends ETH on claim
    function _setupMockWithdrawalQueue(uint256 ethToSend) internal {
        // Deploy mock and etch its code onto the real withdrawal queue address
        MockWithdrawalQueue mock = new MockWithdrawalQueue();
        vm.etch(WITHDRAWAL_QUEUE_ADDR, address(mock).code);
        // Fund the mock so it can send ETH on claim
        vm.deal(WITHDRAWAL_QUEUE_ADDR, ethToSend);
    }

    /// @notice Helper to setup wstETH in strategy for withdrawal tests
    /// @dev Unwinds position and converts WETH to wstETH
    function _setupWstETHForWithdrawal(
        uint256 _amount
    ) internal returns (uint256 wstETHAmount) {
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Fully unwind the leveraged position
        vm.prank(emergencyAdmin);
        strategy.manualFullUnwind();

        // Now we have loose WETH, convert to wstETH
        uint256 looseWeth = strategy.balanceOfAsset();
        assertGt(looseWeth, 0, "!loose weth");

        vm.prank(emergencyAdmin);
        strategy.convertAssetToCollateral(looseWeth);

        wstETHAmount = lstLooper.balanceOfCollateralToken();
        assertGt(wstETHAmount, 0, "!wstETH after conversion");
    }

    /*//////////////////////////////////////////////////////////////
                        initiateLSTWithdrawal TESTS
    //////////////////////////////////////////////////////////////*/

    function test_initiateLSTWithdrawal_basic(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Setup wstETH in strategy
        uint256 wstETHBalance = _setupWstETHForWithdrawal(_amount);

        // Calculate stETH equivalent and ensure we're within bounds
        uint256 minWithdrawal = withdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT();
        uint256 maxWithdrawal = withdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT();
        uint256 stETHEquivalent = wstETH.getStETHByWstETH(wstETHBalance);
        vm.assume(stETHEquivalent > minWithdrawal);

        // Cap the withdrawal to max if needed
        uint256 withdrawAmount = wstETHBalance;
        if (stETHEquivalent > maxWithdrawal) {
            withdrawAmount = wstETH.getWstETHByStETH(maxWithdrawal - 1e16);
        }

        uint256 pendingBefore = lstLooper.pendingRedemptions();

        // Initiate withdrawal
        vm.prank(emergencyAdmin);
        uint256 nftId = lstLooper.initiateLSTWithdrawal(withdrawAmount);

        // Verify NFT was created
        assertGt(nftId, 0, "!nftId");

        // Verify pending redemptions increased
        uint256 pendingAfter = lstLooper.pendingRedemptions();
        assertGt(pendingAfter, pendingBefore, "!pending increased");
    }

    function test_initiateLSTWithdrawal_accessControl() public {
        uint256 _amount = 10e18;

        // Setup wstETH in strategy
        _setupWstETHForWithdrawal(_amount);

        // Random user should fail
        vm.expectRevert("!emergency authorized");
        vm.prank(user);
        lstLooper.initiateLSTWithdrawal(1e18);

        // Keeper should fail
        vm.expectRevert("!emergency authorized");
        vm.prank(keeper);
        lstLooper.initiateLSTWithdrawal(1e18);

        // Management should succeed
        vm.prank(management);
        uint256 nftId = lstLooper.initiateLSTWithdrawal(1e18);
        assertGt(nftId, 0, "!management call");

        // EmergencyAdmin should succeed (using remaining wstETH)
        vm.prank(emergencyAdmin);
        nftId = lstLooper.initiateLSTWithdrawal(1e18);
        assertGt(nftId, 0, "!emergencyAdmin call");
    }

    function test_initiateLSTWithdrawal_belowMinimum() public {
        uint256 _amount = 10e18;

        // Setup wstETH in strategy
        _setupWstETHForWithdrawal(_amount);

        // Attempt withdrawal below minimum (use tiny amount of wstETH)
        uint256 minWithdrawal = withdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT();
        uint256 tooSmall = wstETH.getWstETHByStETH(minWithdrawal / 2);

        vm.expectRevert("!minimum");
        vm.prank(emergencyAdmin);
        lstLooper.initiateLSTWithdrawal(tooSmall);
    }

    function test_initiateLSTWithdrawal_aboveMaximum() public {
        // Setup with large amount
        uint256 _amount = 2000e18;

        // Need large amount of wstETH
        airdrop(asset, user, _amount);
        depositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Fully unwind
        vm.prank(emergencyAdmin);
        strategy.manualFullUnwind();

        // Convert all WETH to wstETH
        uint256 looseWeth = strategy.balanceOfAsset();
        vm.prank(emergencyAdmin);
        strategy.convertAssetToCollateral(looseWeth);

        uint256 maxWithdrawal = withdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT();
        uint256 tooLarge = wstETH.getWstETHByStETH(maxWithdrawal + 1e18);

        // Should revert if stETH equivalent exceeds max
        vm.expectRevert("!maximum");
        vm.prank(emergencyAdmin);
        lstLooper.initiateLSTWithdrawal(tooLarge);
    }

    function test_initiateLSTWithdrawal_capsToBalance() public {
        uint256 _amount = 10e18;

        // Setup wstETH in strategy
        uint256 wstETHBalance = _setupWstETHForWithdrawal(_amount);

        // Request more than available - should cap to balance
        uint256 requestAmount = wstETHBalance * 2;
        uint256 pendingBefore = lstLooper.pendingRedemptions();

        vm.prank(emergencyAdmin);
        lstLooper.initiateLSTWithdrawal(requestAmount);

        // Pending should reflect the capped amount (actual stETH from unwrap)
        uint256 pendingAfter = lstLooper.pendingRedemptions();
        uint256 expectedStETH = wstETH.getStETHByWstETH(wstETHBalance);

        // Allow for some rounding (stETH has rounding)
        assertApproxEqRel(
            pendingAfter - pendingBefore,
            expectedStETH,
            0.01e18,
            "!pending capped"
        );
    }

    function test_initiateLSTWithdrawal_multipleRequests() public {
        uint256 _amount = 20e18;

        // Setup wstETH in strategy
        uint256 wstETHBalance = _setupWstETHForWithdrawal(_amount);
        uint256 halfBalance = wstETHBalance / 2;

        // First withdrawal
        vm.prank(emergencyAdmin);
        uint256 nftId1 = lstLooper.initiateLSTWithdrawal(halfBalance);

        uint256 pendingAfterFirst = lstLooper.pendingRedemptions();

        // Second withdrawal (uses remaining wstETH)
        vm.prank(emergencyAdmin);
        uint256 nftId2 = lstLooper.initiateLSTWithdrawal(halfBalance);

        uint256 pendingAfterSecond = lstLooper.pendingRedemptions();

        // Verify both NFTs created and pending accumulated
        assertGt(nftId1, 0, "!nftId1");
        assertGt(nftId2, 0, "!nftId2");
        assertGt(nftId2, nftId1, "!nftId order");
        assertGt(pendingAfterSecond, pendingAfterFirst, "!pending accumulated");
    }

    /*//////////////////////////////////////////////////////////////
                        claimLSTWithdrawal TESTS
    //////////////////////////////////////////////////////////////*/

    function test_claimLSTWithdrawal_accessControl() public {
        // Use a fake claim ID for access control test
        uint256 fakeClaimId = 12345;

        // Random user should fail
        vm.expectRevert("!emergency authorized");
        vm.prank(user);
        lstLooper.claimLSTWithdrawal(fakeClaimId);

        // Keeper should fail
        vm.expectRevert("!emergency authorized");
        vm.prank(keeper);
        lstLooper.claimLSTWithdrawal(fakeClaimId);
    }

    function test_claimLSTWithdrawal_withMock(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Setup wstETH in strategy
        uint256 wstETHBalance = _setupWstETHForWithdrawal(_amount);

        // Calculate valid withdrawal amount
        uint256 minWithdrawal = withdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT();
        uint256 maxWithdrawal = withdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT();
        uint256 stETHEquivalent = wstETH.getStETHByWstETH(wstETHBalance);
        vm.assume(stETHEquivalent > minWithdrawal);

        uint256 withdrawAmount = wstETHBalance;
        if (stETHEquivalent > maxWithdrawal) {
            withdrawAmount = wstETH.getWstETHByStETH(maxWithdrawal - 1e16);
        }

        vm.prank(emergencyAdmin);
        uint256 nftId = lstLooper.initiateLSTWithdrawal(withdrawAmount);

        uint256 pendingBefore = lstLooper.pendingRedemptions();
        uint256 wethBefore = asset.balanceOf(address(lstLooper));

        // Setup mock withdrawal queue that sends ETH on claim
        _setupMockWithdrawalQueue(pendingBefore);

        vm.prank(emergencyAdmin);
        lstLooper.claimLSTWithdrawal(nftId);

        // Verify WETH balance increased
        uint256 wethAfter = asset.balanceOf(address(lstLooper));
        assertGt(wethAfter, wethBefore, "!weth increased");

        // Verify pending reduced (should be 0 since we claimed exact amount)
        uint256 pendingAfter = lstLooper.pendingRedemptions();
        assertEq(pendingAfter, 0, "!pending cleared");
    }

    function test_claimLSTWithdrawal_reducesPendingCorrectly() public {
        uint256 _amount = 20e18;

        // Setup wstETH in strategy
        uint256 wstETHBalance = _setupWstETHForWithdrawal(_amount);
        uint256 halfBalance = wstETHBalance / 2;

        // First withdrawal
        vm.prank(emergencyAdmin);
        uint256 nftId1 = lstLooper.initiateLSTWithdrawal(halfBalance);

        uint256 pendingAfterFirst = lstLooper.pendingRedemptions();

        // Second withdrawal (uses remaining wstETH)
        vm.prank(emergencyAdmin);
        uint256 nftId2 = lstLooper.initiateLSTWithdrawal(halfBalance);

        uint256 totalPending = lstLooper.pendingRedemptions();
        assertGt(totalPending, pendingAfterFirst, "!total pending");

        // Claim first withdrawal - setup mock with exact amount for first claim
        uint256 claimAmount1 = pendingAfterFirst;
        _setupMockWithdrawalQueue(claimAmount1);

        vm.prank(emergencyAdmin);
        lstLooper.claimLSTWithdrawal(nftId1);

        uint256 pendingAfterFirstClaim = lstLooper.pendingRedemptions();
        assertLt(
            pendingAfterFirstClaim,
            totalPending,
            "!pending reduced after first claim"
        );
        assertGt(pendingAfterFirstClaim, 0, "!pending should still exist");

        // Claim second withdrawal - setup mock with remaining pending
        _setupMockWithdrawalQueue(pendingAfterFirstClaim);

        vm.prank(emergencyAdmin);
        lstLooper.claimLSTWithdrawal(nftId2);

        uint256 pendingAfterSecondClaim = lstLooper.pendingRedemptions();

        // After claiming both, pending should be 0
        assertEq(
            pendingAfterSecondClaim,
            0,
            "!pending cleared after both claims"
        );
    }

    function test_claimLSTWithdrawal_convertsEthToWeth() public {
        uint256 _amount = 10e18;

        // Setup wstETH in strategy
        _setupWstETHForWithdrawal(_amount);

        vm.prank(emergencyAdmin);
        uint256 nftId = lstLooper.initiateLSTWithdrawal(1e18);

        uint256 wethBefore = asset.balanceOf(address(lstLooper));
        uint256 pendingAmount = lstLooper.pendingRedemptions();

        // Setup mock to send exact pending amount
        _setupMockWithdrawalQueue(pendingAmount);

        vm.prank(emergencyAdmin);
        lstLooper.claimLSTWithdrawal(nftId);

        // All ETH should be converted to WETH
        uint256 wethAfter = asset.balanceOf(address(lstLooper));
        assertEq(address(lstLooper).balance, 0, "!eth should be 0");
        assertEq(
            wethAfter - wethBefore,
            pendingAmount,
            "!weth increase matches eth received"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fullWithdrawalFlow_integration(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // 1. Setup leveraged position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        assertGt(strategy.balanceOfCollateral(), 0, "!collateral");
        assertGt(strategy.balanceOfDebt(), 0, "!debt");

        // 2. Shutdown and unwind
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.prank(emergencyAdmin);
        strategy.manualFullUnwind();

        // 3. Now have loose assets - convert to wstETH for LST withdrawal
        uint256 looseAssets = strategy.balanceOfAsset();
        assertGt(looseAssets, 0, "!loose assets after unwind");

        vm.prank(emergencyAdmin);
        strategy.convertAssetToCollateral(looseAssets);

        uint256 wstETHBalance = lstLooper.balanceOfCollateralToken();
        assertGt(wstETHBalance, 0, "!wstETH after conversion");

        // 4. Initiate LST withdrawal
        uint256 minWithdrawal = withdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT();
        uint256 stETHEquivalent = wstETH.getStETHByWstETH(wstETHBalance);
        vm.assume(stETHEquivalent > minWithdrawal);

        // Cap withdrawal to max
        uint256 maxWithdrawal = withdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT();
        uint256 withdrawAmount = wstETHBalance;
        if (stETHEquivalent > maxWithdrawal) {
            withdrawAmount = wstETH.getWstETHByStETH(maxWithdrawal - 1e16);
        }

        vm.prank(emergencyAdmin);
        uint256 nftId = lstLooper.initiateLSTWithdrawal(withdrawAmount);

        assertGt(nftId, 0, "!nft created");
        uint256 pendingAmount = lstLooper.pendingRedemptions();
        assertGt(pendingAmount, 0, "!pending set");

        // 5. Setup mock to send ETH on claim
        _setupMockWithdrawalQueue(pendingAmount);

        uint256 wethBefore = asset.balanceOf(address(lstLooper));

        vm.prank(emergencyAdmin);
        lstLooper.claimLSTWithdrawal(nftId);

        // 6. Verify final state
        uint256 wethAfter = asset.balanceOf(address(lstLooper));
        assertGt(wethAfter, wethBefore, "!weth recovered");

        // Pending should be cleared (claimed amount >= pending)
        assertEq(lstLooper.pendingRedemptions(), 0, "!pending cleared");
    }

    function test_pendingRedemptions_initiallyZero() public view {
        assertEq(lstLooper.pendingRedemptions(), 0, "!initial pending");
    }

    function test_receive_acceptsEth() public {
        // Strategy should accept ETH (needed for withdrawal claims)
        vm.deal(address(this), 1 ether);
        (bool success, ) = address(lstLooper).call{value: 1 ether}("");
        assertTrue(success, "!receive eth");
    }

    function test_initiateLSTWithdrawal_noWstETH_reverts() public {
        // Setup position but don't convert to wstETH
        mintAndDepositIntoStrategy(strategy, user, 10e18);
        vm.prank(keeper);
        strategy.tend();

        // No loose wstETH in strategy
        assertEq(lstLooper.balanceOfCollateralToken(), 0, "!no wstETH");

        // Should revert because there's no wstETH to withdraw
        // (amount gets capped to 0, unwrap(0) reverts from wstETH contract)
        vm.expectRevert("wstETH: zero amount unwrap not allowed");
        vm.prank(emergencyAdmin);
        lstLooper.initiateLSTWithdrawal(1e18);
    }

    function test_pendingRedemptions_accumulates() public {
        uint256 _amount = 30e18;

        // Setup wstETH
        uint256 wstETHBalance = _setupWstETHForWithdrawal(_amount);
        uint256 thirdBalance = wstETHBalance / 3;

        assertEq(lstLooper.pendingRedemptions(), 0, "!initial zero");

        // First withdrawal
        vm.prank(emergencyAdmin);
        lstLooper.initiateLSTWithdrawal(thirdBalance);
        uint256 pending1 = lstLooper.pendingRedemptions();
        assertGt(pending1, 0, "!pending after first");

        // Second withdrawal
        vm.prank(emergencyAdmin);
        lstLooper.initiateLSTWithdrawal(thirdBalance);
        uint256 pending2 = lstLooper.pendingRedemptions();
        assertGt(pending2, pending1, "!pending accumulated");

        // Third withdrawal
        vm.prank(emergencyAdmin);
        lstLooper.initiateLSTWithdrawal(thirdBalance);
        uint256 pending3 = lstLooper.pendingRedemptions();
        assertGt(pending3, pending2, "!pending accumulated again");
    }
}
