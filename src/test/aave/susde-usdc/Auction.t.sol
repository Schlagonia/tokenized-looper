// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SetupAavesUSDeUSDC} from "./Setup.sol";
import {IAaveLooper} from "../../../interfaces/IAaveLooper.sol";
import {IAaveOracle} from "../../../interfaces/aave/IAaveOracle.sol";

contract AavesUSDeUSDCAuctionTest is SetupAavesUSDeUSDC {
    function setUp() public override {
        SetupAavesUSDeUSDC.setUp();
    }

    function setUpStrategy()
        public
        override(SetupAavesUSDeUSDC)
        returns (address)
    {
        return SetupAavesUSDeUSDC.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupAavesUSDeUSDC) {
        SetupAavesUSDeUSDC.accrueYield(_amount);
    }

    function test_assetAuction_fullTakeBuildsLeverageNearTarget() public {
        uint256 amount = _testAmount();
        (uint256 available, uint256 idle) = _kickAssetAuction(amount);

        assertGt(available, idle, "!flashloan leg");

        uint256 oracleQuote = _oracleAssetToCollateral(available);
        uint256 auctionQuote = strategy.getAmountNeeded(address(asset), available);
        uint256 maxOracleQuote = (oracleQuote * (MAX_BPS + strategy.slippage())) /
            MAX_BPS;

        assertGe(auctionQuote, oracleQuote, "!auction below oracle");
        assertLe(auctionQuote, maxOracleQuote + 2, "!auction too rich");

        _fundAndApprove(strategy.collateralToken(), user, auctionQuote);

        vm.prank(user);
        uint256 taken = strategy.take(address(asset), available, user, "");

        assertEq(taken, available, "!taken");
        assertEq(strategy.activeAuction(), address(0), "!active auction");
        assertEq(strategy.available(address(asset)), 0, "!available");
        assertEq(
            ERC20(strategy.collateralToken()).balanceOf(address(strategy)),
            0,
            "!loose collateral"
        );
        assertGt(strategy.balanceOfCollateral(), 0, "!collateral");
        assertGt(strategy.balanceOfDebt(), 0, "!debt");

        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();

        assertGe(leverageAfter, target - buffer, "!leverage low");
        assertLe(leverageAfter, target + buffer, "!leverage high");
    }

    function test_assetAuction_partialTakeSuppliesCollateralAndKeepsNoDebt()
        public
    {
        uint256 amount = _testAmount();
        (, uint256 idle) = _kickAssetAuction(amount);

        uint256 partialTake = idle / 2;
        assertGt(partialTake, 0, "!partial");

        uint256 oracleQuote = _oracleAssetToCollateral(partialTake);
        uint256 auctionQuote = strategy.getAmountNeeded(
            address(asset),
            partialTake
        );
        uint256 maxOracleQuote = (oracleQuote * (MAX_BPS + strategy.slippage())) /
            MAX_BPS;

        assertGe(auctionQuote, oracleQuote, "!auction below oracle");
        assertLe(auctionQuote, maxOracleQuote + 2, "!auction too rich");

        address taker = makeAddr("partial-taker");
        _fundAndApprove(strategy.collateralToken(), taker, auctionQuote);

        vm.prank(taker);
        uint256 taken = strategy.take(address(asset), partialTake, taker, "");

        assertEq(taken, partialTake, "!taken");
        assertGt(strategy.balanceOfCollateral(), 0, "!supplied collateral");
        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertEq(strategy.getCurrentLeverageRatio(), 1e18, "!leverage");
        assertEq(
            ERC20(strategy.collateralToken()).balanceOf(address(strategy)),
            0,
            "!loose collateral"
        );
        assertTrue(strategy.isActive(address(asset)), "!asset auction");
        assertGt(strategy.available(address(asset)), 0, "!remaining");
    }

    function test_assetAuction_partialThenFullTakeBuildsLeverage() public {
        uint256 amount = _testAmount();
        (, uint256 idle) = _kickAssetAuction(amount);

        uint256 partialTake = idle / 2;
        assertGt(partialTake, 0, "!partial");

        address firstTaker = makeAddr("first-taker");
        _fundAndApprove(
            strategy.collateralToken(),
            firstTaker,
            strategy.getAmountNeeded(address(asset), partialTake)
        );

        vm.prank(firstTaker);
        strategy.take(address(asset), partialTake, firstTaker, "");

        uint256 remaining = strategy.available(address(asset));
        address secondTaker = makeAddr("second-taker");
        uint256 remainingNeed = strategy.getAmountNeeded(address(asset), remaining);
        _fundAndApprove(
            strategy.collateralToken(),
            secondTaker,
            remainingNeed
        );

        vm.prank(secondTaker);
        uint256 taken = strategy.take(address(asset), remaining, secondTaker, "");

        assertEq(taken, remaining, "!taken");
        assertEq(strategy.activeAuction(), address(0), "!active auction");
        assertEq(strategy.available(address(asset)), 0, "!available");
        assertEq(
            ERC20(strategy.collateralToken()).balanceOf(address(strategy)),
            0,
            "!loose collateral"
        );
        assertGt(strategy.balanceOfCollateral(), 0, "!collateral");
        assertGt(strategy.balanceOfDebt(), 0, "!debt");

        uint256 leverageAfter = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();

        assertGe(leverageAfter, target - buffer, "!leverage low");
        assertLe(leverageAfter, target + buffer, "!leverage high");
    }

    function test_collateralAuction_fullTakeImprovesOverleveredPosition()
        public
    {
        uint256 amount = _testAmount();
        (uint256 available, ) = _kickAssetAuction(amount);

        address leverTaker = makeAddr("lever-taker");
        _fundAndApprove(
            strategy.collateralToken(),
            leverTaker,
            strategy.getAmountNeeded(address(asset), available)
        );

        vm.prank(leverTaker);
        strategy.take(address(asset), available, leverTaker, "");

        uint256 leverageBefore = strategy.getCurrentLeverageRatio();
        uint256 debtBefore = strategy.balanceOfDebt();
        uint256 collateralBefore = strategy.balanceOfCollateral();

        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.25e18, 2.5e18);

        vm.prank(keeper);
        strategy.tend();

        address collateral = strategy.collateralToken();
        uint256 collateralAvailable = strategy.available(collateral);
        uint256 oracleQuote = _oracleCollateralToAsset(collateralAvailable);
        uint256 auctionQuote = strategy.getAmountNeeded(
            collateral,
            collateralAvailable
        );
        uint256 maxOracleQuote = (oracleQuote *
            (MAX_BPS + strategy.slippage())) / MAX_BPS;

        assertEq(strategy.activeAuction(), collateral, "!active auction");
        assertGt(collateralAvailable, 0, "!collateral available");
        assertGe(auctionQuote, oracleQuote, "!auction below oracle");
        assertLe(auctionQuote, maxOracleQuote + 2, "!auction too rich");

        address deleverTaker = makeAddr("delever-taker");
        _fundAndApprove(address(asset), deleverTaker, auctionQuote);

        vm.prank(deleverTaker);
        strategy.take(collateral, collateralAvailable, deleverTaker, "");

        assertEq(strategy.activeAuction(), address(0), "!active auction");
        assertLt(strategy.balanceOfDebt(), debtBefore, "!debt");
        assertLt(strategy.balanceOfCollateral(), collateralBefore, "!collateral");
        assertLt(
            strategy.getCurrentLeverageRatio(),
            leverageBefore,
            "!leverage"
        );
    }

    function _kickAssetAuction(
        uint256 _amount
    ) internal returns (uint256 available, uint256 idle) {
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        idle = strategy.balanceOfAsset();
        available = strategy.available(address(asset));

        assertEq(strategy.activeAuction(), address(asset), "!active auction");
        assertGt(available, 0, "!available");
        assertGt(idle, 0, "!idle");
    }

    function _fundAndApprove(
        address _token,
        address _owner,
        uint256 _amount
    ) internal {
        deal(_token, _owner, _amount);

        vm.prank(_owner);
        ERC20(_token).approve(address(strategy), type(uint256).max);
    }

    function _oracleAssetToCollateral(
        uint256 _assetAmount
    ) internal view returns (uint256) {
        IAaveOracle oracle = IAaveLooper(address(strategy)).AAVE_ORACLE();
        uint256 assetPrice = oracle.getAssetPrice(address(asset));
        uint256 collateralPrice = oracle.getAssetPrice(strategy.collateralToken());

        return
            (_assetAmount *
                assetPrice *
                (10 ** ERC20(strategy.collateralToken()).decimals())) /
            (collateralPrice * (10 ** asset.decimals()));
    }

    function _oracleCollateralToAsset(
        uint256 _collateralAmount
    ) internal view returns (uint256) {
        IAaveOracle oracle = IAaveLooper(address(strategy)).AAVE_ORACLE();
        uint256 assetPrice = oracle.getAssetPrice(address(asset));
        uint256 collateralPrice = oracle.getAssetPrice(strategy.collateralToken());

        return
            (_collateralAmount *
                collateralPrice *
                (10 ** asset.decimals())) /
            (assetPrice * (10 ** ERC20(strategy.collateralToken()).decimals()));
    }

    function _testAmount() internal view returns (uint256) {
        uint256 min = minFuzzAmount;
        uint256 max = maxFuzzAmount;
        if (max <= min) return min;

        uint256 mid = (min + max) / 2;
        return mid > min ? mid : min;
    }
}
