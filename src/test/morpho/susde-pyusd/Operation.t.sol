// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupSUSDePYUSD} from "./Setup.sol";
import {MetaExchange} from "../../../periphery/exchanges/MetaExchange.sol";

contract sUSDePYUSDMorphoOperationTest is SetupSUSDePYUSD, OperationTest {
    /// @dev Aave's sUSDe suite uses 15 BPS; the extra Curve hop here can leave
    ///      a touch more dust, but 15 BPS still holds within real fork spreads.
    uint256 internal constant SUSDE_UNWIND_DUST_BPS = 15;

    function setUp() public override(SetupSUSDePYUSD, OperationTest) {
        SetupSUSDePYUSD.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSUSDePYUSD, Setup)
        returns (address)
    {
        return SetupSUSDePYUSD.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSUSDePYUSD, Setup) {
        SetupSUSDePYUSD.accrueYield(_amount);
    }

    function _maxUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure override returns (uint256) {
        uint256 relativeDust = collateralBeforeUnwind /
            (10_000 / SUSDE_UNWIND_DUST_BPS);
        return
            relativeDust > MIN_UNWIND_COLLATERAL_DUST
                ? relativeDust
                : MIN_UNWIND_COLLATERAL_DUST;
    }

    /*//////////////////////////////////////////////////////////////
                        ROUTE / CONFIG SANITY
    //////////////////////////////////////////////////////////////*/

    function test_exchange_coreConfig() public view {
        assertEq(fluidExchange.fluidBase(), USDT, "!fluid base");

        MetaExchange.RouteStep[] memory forward = exchange.getRoute(
            PYUSD,
            SUSDE
        );
        assertEq(forward.length, 3, "!forward length");
        assertEq(forward[0].exchange, address(curveExchange), "!fwd ex 0");
        assertEq(forward[0].tokenTo, USDC, "!fwd token 0");
        assertEq(forward[1].exchange, address(fluidExchange), "!fwd ex 1");
        assertEq(forward[1].tokenTo, USDE, "!fwd token 1");
        assertEq(forward[2].exchange, address(erc4626Exchange), "!fwd ex 2");
        assertEq(forward[2].tokenTo, SUSDE, "!fwd token 2");

        MetaExchange.RouteStep[] memory unwind = exchange.getRoute(
            SUSDE,
            PYUSD
        );
        assertEq(unwind.length, 2, "!unwind length");
        assertEq(unwind[0].exchange, address(fluidExchange), "!unwind ex 0");
        assertEq(unwind[0].tokenTo, USDC, "!unwind token 0");
        assertEq(unwind[1].exchange, address(curveExchange), "!unwind ex 1");
        assertEq(unwind[1].tokenTo, PYUSD, "!unwind token 1");

        MetaExchange.RouteStep[] memory underlying = exchange.getRoute(
            USDE,
            PYUSD
        );
        assertEq(underlying.length, 2, "!underlying length");
        assertEq(
            underlying[0].exchange,
            address(fluidExchange),
            "!underlying ex 0"
        );
        assertEq(underlying[0].tokenTo, USDC, "!underlying token 0");
        assertEq(
            underlying[1].exchange,
            address(curveExchange),
            "!underlying ex 1"
        );
        assertEq(underlying[1].tokenTo, PYUSD, "!underlying token 1");
    }

    function test_setupStrategyOK() public override {
        OperationTest.test_setupStrategyOK();

        assertEq(strategy.collateralToken(), SUSDE, "!collateralToken");
        assertEq(cooldownAdapter.UNDERLYING(), USDE, "!UNDERLYING");
        assertEq(
            cooldownAdapter.pendingRedemptions(),
            0,
            "!pendingRedemptions init"
        );
    }

    function test_setExchange_onlyGovernance() public {
        MetaExchange newExchange = new MetaExchange(WETH);

        vm.prank(user);
        vm.expectRevert("!governance");
        strategy.setExchange(address(newExchange));

        vm.prank(management);
        strategy.setExchange(address(newExchange));
        assertEq(strategy.exchange(), address(newExchange), "!exchange set");
    }

    /*//////////////////////////////////////////////////////////////
                        COOLDOWN STATE MACHINE
    //////////////////////////////////////////////////////////////*/

    function test_cooldown_functions_onlyEmergencyAuthorized() public {
        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        strategy.clearCooldown("");

        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        strategy.initiateCooldown(0, "");

        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        strategy.claimCooldown("");

        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        strategy.convertCooldownTokenToAsset(0);

        vm.prank(emergencyAdmin);
        strategy.clearCooldown("");
    }

    function test_estimatedTotalAssets_countsPendingCooldownSharesInAssetTerms()
        public
    {
        uint256 depositAmount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        vm.prank(keeper);
        strategy.tend();

        uint256 withdrawShares = strategy.balanceOfCollateral() / 20;
        assertGt(withdrawShares, 0, "!withdrawShares");

        vm.prank(emergencyAdmin);
        strategy.manualWithdrawCollateral(withdrawShares);

        uint256 looseShares = strategy.balanceOfCollateralToken();
        assertGt(looseShares, 0, "!looseShares");

        uint256 estimatedBeforeCooldown = strategy.estimatedTotalAssets();

        vm.prank(emergencyAdmin);
        uint256 cooldownAssets = abi.decode(
            strategy.initiateCooldown(looseShares, ""),
            (uint256)
        );

        assertEq(
            cooldownAdapter.pendingRedemptions(),
            cooldownAssets,
            "!pendingRedemptions"
        );
        assertEq(
            strategy.balanceOfCollateralToken(),
            0,
            "!looseShares cleared"
        );

        uint256 estimatedAfterCooldown = strategy.estimatedTotalAssets();
        (uint256 collateralValueAfter, uint256 debtAfter) = strategy.position();
        uint256 estimatedWithoutPending = strategy.balanceOfAsset() +
            collateralValueAfter -
            debtAfter;

        assertApproxEqAbs(
            estimatedAfterCooldown,
            estimatedBeforeCooldown,
            1,
            "!estimatedTotalAssets"
        );
        assertGt(
            estimatedAfterCooldown,
            estimatedWithoutPending,
            "!pendingRedemptions not counted"
        );
    }

    function test_initiateCooldown_revertsWhileAlreadyPending() public {
        uint256 depositAmount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        vm.prank(keeper);
        strategy.tend();

        uint256 withdrawShares = strategy.balanceOfCollateral() / 20;
        vm.prank(emergencyAdmin);
        strategy.manualWithdrawCollateral(withdrawShares);

        uint256 looseShares = strategy.balanceOfCollateralToken();
        vm.prank(emergencyAdmin);
        strategy.initiateCooldown(looseShares / 2, "");

        // Stage another loose chunk so the second call would otherwise succeed.
        vm.prank(emergencyAdmin);
        strategy.manualWithdrawCollateral(withdrawShares);

        uint256 freshLoose = strategy.balanceOfCollateralToken();
        vm.prank(emergencyAdmin);
        vm.expectRevert("pending redemptions");
        strategy.initiateCooldown(freshLoose, "");
    }

    function test_report_revertsWhilePendingRedemptionsOutstanding() public {
        uint256 depositAmount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        vm.prank(keeper);
        strategy.tend();

        uint256 withdrawShares = strategy.balanceOfCollateral() / 20;
        vm.prank(emergencyAdmin);
        strategy.manualWithdrawCollateral(withdrawShares);

        uint256 looseShares = strategy.balanceOfCollateralToken();
        vm.prank(emergencyAdmin);
        strategy.initiateCooldown(looseShares, "");

        assertGt(
            cooldownAdapter.pendingRedemptions(),
            0,
            "!pending precondition"
        );

        vm.prank(keeper);
        vm.expectRevert("pending cooldown");
        strategy.report();
    }

    function test_zeroPendingRedemptions_clearsAccountingOnly() public {
        uint256 depositAmount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        vm.prank(keeper);
        strategy.tend();

        uint256 withdrawShares = strategy.balanceOfCollateral() / 20;
        vm.prank(emergencyAdmin);
        strategy.manualWithdrawCollateral(withdrawShares);

        uint256 looseShares = strategy.balanceOfCollateralToken();
        vm.prank(emergencyAdmin);
        strategy.initiateCooldown(looseShares, "");
        assertGt(cooldownAdapter.pendingRedemptions(), 0, "!pending");

        vm.prank(emergencyAdmin);
        strategy.clearCooldown("");

        assertEq(cooldownAdapter.pendingRedemptions(), 0, "!pending cleared");

        vm.prank(management);
        strategy.setDoHealthCheck(false);
        vm.prank(keeper);
        strategy.report();
    }

    function test_convertUnderlyingToAsset_afterCooldown_unstakesAndSwapsToPYUSD()
        public
    {
        uint256 depositAmount = _baseTestAmount();
        mintAndDepositIntoStrategy(strategy, user, depositAmount);

        vm.prank(keeper);
        strategy.tend();

        uint256 withdrawShares = strategy.balanceOfCollateral() / 20;
        assertGt(withdrawShares, 0, "!withdrawShares");

        vm.prank(emergencyAdmin);
        strategy.manualWithdrawCollateral(withdrawShares);

        uint256 looseShares = strategy.balanceOfCollateralToken();
        vm.prank(emergencyAdmin);
        uint256 cooldownAssets = abi.decode(
            strategy.initiateCooldown(looseShares, ""),
            (uint256)
        );

        assertGt(cooldownAssets, 0, "!cooldownAssets");
        assertEq(
            cooldownAdapter.pendingRedemptions(),
            cooldownAssets,
            "!pending"
        );

        // Ethena cooldown is 7 days; pad to 8 to be safe across forks.
        skip(8 days);

        vm.prank(emergencyAdmin);
        strategy.claimCooldown("");

        uint256 underlyingBalance = ERC20(USDE).balanceOf(address(strategy));
        uint256 assetBefore = strategy.balanceOfAsset();

        assertGt(underlyingBalance, 0, "!underlying");
        assertEq(cooldownAdapter.pendingRedemptions(), 0, "!pending cleared");

        vm.prank(emergencyAdmin);
        uint256 amountOut = strategy.convertCooldownTokenToAsset(
            type(uint256).max
        );

        assertGt(amountOut, 0, "!amountOut");
        assertEq(
            ERC20(USDE).balanceOf(address(strategy)),
            0,
            "!underlying cleared"
        );
        assertEq(
            strategy.balanceOfAsset(),
            assetBefore + amountOut,
            "!asset balance"
        );
    }
}
