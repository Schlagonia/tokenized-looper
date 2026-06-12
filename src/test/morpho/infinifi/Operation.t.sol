// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {OperationTest} from "../../base/Operation.t.sol";
import {InfinifiMorphoLooper} from "../../../morpho/InfinifiMorphoLooper.sol";
import {IInfiniFiGatewayV1} from "../../../interfaces/infinifi/IInfiniFiGatewayV1.sol";
import {IRedeemController} from "../../../interfaces/infinifi/IRedeemController.sol";

interface MorphoInfinifiCore {
    function getRoleMember(
        bytes32 role,
        uint256 index
    ) external view returns (address);
}

interface MorphoInfinifiRedeemController is IRedeemController {
    function core() external view returns (address);

    function beforeRedeemHook() external view returns (address);

    function setBeforeRedeemHook(address hook) external;

    function deposit() external;

    function withdraw(uint256 amount, address to) external;

    function totalEnqueuedRedemptions() external view returns (uint256);
}

/// @notice Infinifi Operation tests - uses base Setup which deploys InfinifiMorphoLooper
contract InfinifiOperationTest is OperationTest {
    bytes32 internal constant FARM_MANAGER = keccak256("FARM_MANAGER");
    bytes32 internal constant GOVERNOR = keccak256("GOVERNOR");

    function setUp() public override {
        super.setUp();
    }

    function test_redemptionQueue_accessControl() public {
        InfinifiMorphoLooper looper = InfinifiMorphoLooper(address(strategy));

        vm.prank(user);
        vm.expectRevert("!management");
        looper.zeroPendingRedemptions();

        vm.prank(user);
        vm.expectRevert("!management");
        looper.initiateCooldown(1);

        vm.prank(user);
        vm.expectRevert("!keeper");
        looper.claimCooldown();

        vm.prank(management);
        looper.zeroPendingRedemptions();
    }

    function test_initiateCooldown_tracksQueuedAssets() public {
        (
            InfinifiMorphoLooper looper,
            uint256 looseShares
        ) = _stageLooseInfinifiShares();

        MorphoInfinifiRedeemController controller = _prepareLiveRedeemController();
        uint256 totalQueuedBefore = controller.totalEnqueuedRedemptions();

        vm.prank(management);
        (uint256 assetsOut, uint256 queuedAssets) = looper.initiateCooldown(
            looseShares
        );

        assertEq(assetsOut, 0, "!assetsOut");
        assertGt(queuedAssets, 0, "!queued");
        assertEq(looper.pendingRedemptions(), queuedAssets, "!pending");
        assertEq(looper.balanceOfCollateralToken(), 0, "!loose");
        assertEq(controller.queueLength(), 1, "!queue");
        assertGt(
            controller.totalEnqueuedRedemptions(),
            totalQueuedBefore,
            "!enqueued"
        );
        assertEq(
            controller.userPendingClaims(address(looper)),
            0,
            "!claimable"
        );
    }

    function test_estimatedTotalAssets_includesPendingRedemptions() public {
        (
            InfinifiMorphoLooper looper,
            uint256 looseShares
        ) = _stageLooseInfinifiShares();

        _prepareLiveRedeemController();

        vm.prank(management);
        (, uint256 queuedAssets) = looper.initiateCooldown(looseShares);

        (uint256 collateralValue, uint256 debt) = looper.position();
        uint256 withoutPending = looper.balanceOfAsset() +
            collateralValue -
            debt;

        assertEq(
            looper.estimatedTotalAssets(),
            withoutPending + queuedAssets,
            "!pending counted"
        );
    }

    function test_report_revertsWhilePendingRedemptionsOutstanding() public {
        (
            InfinifiMorphoLooper looper,
            uint256 looseShares
        ) = _stageLooseInfinifiShares();

        _prepareLiveRedeemController();

        vm.prank(management);
        looper.initiateCooldown(looseShares);

        assertGt(looper.pendingRedemptions(), 0, "!pending");

        vm.prank(keeper);
        vm.expectRevert("pending redemptions");
        strategy.report();
    }

    function test_initiateCooldown_revertsWhileAlreadyPending() public {
        (
            InfinifiMorphoLooper looper,
            uint256 looseShares
        ) = _stageLooseInfinifiShares();

        _prepareLiveRedeemController();

        vm.prank(management);
        looper.initiateCooldown(looseShares);

        vm.prank(management);
        vm.expectRevert("pending redemptions");
        looper.initiateCooldown(1);
    }

    function test_zeroPendingRedemptions_clearsAccountingOnly() public {
        (
            InfinifiMorphoLooper looper,
            uint256 looseShares
        ) = _stageLooseInfinifiShares();

        _prepareLiveRedeemController();

        vm.prank(management);
        looper.initiateCooldown(looseShares);
        assertGt(looper.pendingRedemptions(), 0, "!pending");

        vm.prank(management);
        looper.zeroPendingRedemptions();

        assertEq(looper.pendingRedemptions(), 0, "!pending cleared");
    }

    function test_claimCooldown_clearsPendingWithClaimedAssets() public {
        (
            InfinifiMorphoLooper looper,
            uint256 looseShares
        ) = _stageLooseInfinifiShares();

        MorphoInfinifiRedeemController controller = _prepareLiveRedeemController();

        vm.prank(management);
        (, uint256 queuedAssets) = looper.initiateCooldown(looseShares);
        assertEq(looper.pendingRedemptions(), queuedAssets, "!pending");
        assertEq(controller.userPendingClaims(address(looper)), 0, "!claim");

        _fundLiveRedemptionQueue(controller, queuedAssets);
        assertEq(
            controller.userPendingClaims(address(looper)),
            queuedAssets,
            "!claim funded"
        );

        uint256 assetBefore = asset.balanceOf(address(looper));

        vm.prank(keeper);
        uint256 claimed = looper.claimCooldown();

        assertEq(claimed, queuedAssets, "!claimed");
        assertEq(looper.pendingRedemptions(), 0, "!pending cleared");
        assertEq(
            asset.balanceOf(address(looper)),
            assetBefore + queuedAssets,
            "!asset balance"
        );
    }

    function test_initiateCooldown_revertsWithoutShares() public {
        InfinifiMorphoLooper looper = InfinifiMorphoLooper(address(strategy));

        vm.prank(management);
        vm.expectRevert("!shares");
        looper.initiateCooldown(type(uint256).max);
    }

    function _stageLooseInfinifiShares()
        internal
        returns (InfinifiMorphoLooper looper, uint256 looseShares)
    {
        mintAndDepositIntoStrategy(strategy, user, _baseTestAmount());

        vm.prank(keeper);
        strategy.tend();

        looper = InfinifiMorphoLooper(address(strategy));

        uint256 withdrawShares = looper.balanceOfCollateral() / 20;
        assertGt(withdrawShares, 0, "!withdrawShares");

        vm.prank(emergencyAdmin);
        looper.manualWithdrawCollateral(withdrawShares);

        looseShares = looper.balanceOfCollateralToken();
        assertGt(looseShares, 0, "!looseShares");
    }

    function _prepareLiveRedeemController()
        internal
        returns (MorphoInfinifiRedeemController controller)
    {
        controller = _liveRedeemController();
        _clearLiveRedemptionQueue(controller);
        _disableLiveBeforeRedeemHook(controller);

        uint256 availableLiquidity = controller.liquidity();
        if (availableLiquidity > 0) {
            vm.prank(_liveFarmManager(controller));
            controller.withdraw(availableLiquidity, address(this));
        }

        assertEq(controller.queueLength(), 0, "!live queue");
        assertEq(controller.liquidity(), 0, "!live liquidity");
    }

    function _clearLiveRedemptionQueue(
        MorphoInfinifiRedeemController controller
    ) internal {
        uint256 queuedReceipts = controller.totalEnqueuedRedemptions();
        if (queuedReceipts == 0) return;

        uint256 assetsRequired = controller.receiptToAsset(queuedReceipts);
        assertGt(assetsRequired, 0, "!assets required");

        deal(
            address(asset),
            address(controller),
            asset.balanceOf(address(controller)) + assetsRequired
        );

        vm.prank(_liveFarmManager(controller));
        controller.deposit();
    }

    function _disableLiveBeforeRedeemHook(
        MorphoInfinifiRedeemController controller
    ) internal {
        if (controller.beforeRedeemHook() == address(0)) return;

        vm.prank(_liveGovernor(controller));
        controller.setBeforeRedeemHook(address(0));
    }

    function _fundLiveRedemptionQueue(
        MorphoInfinifiRedeemController controller,
        uint256 assetsToFund
    ) internal {
        deal(
            address(asset),
            address(controller),
            asset.balanceOf(address(controller)) + assetsToFund
        );

        vm.prank(_liveFarmManager(controller));
        controller.deposit();
    }

    function _liveRedeemController()
        internal
        view
        returns (MorphoInfinifiRedeemController)
    {
        return
            MorphoInfinifiRedeemController(
                IInfiniFiGatewayV1(GATEWAY).getAddress("redeemController")
            );
    }

    function _liveGovernor(
        MorphoInfinifiRedeemController controller
    ) internal view returns (address) {
        return MorphoInfinifiCore(controller.core()).getRoleMember(GOVERNOR, 0);
    }

    function _liveFarmManager(
        MorphoInfinifiRedeemController controller
    ) internal view returns (address) {
        return
            MorphoInfinifiCore(controller.core()).getRoleMember(
                FARM_MANAGER,
                0
            );
    }
}
