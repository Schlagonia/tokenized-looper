// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

    function accrueYield(uint256 _amount) public override(SetupAavesUSDeUSDC) {
        SetupAavesUSDeUSDC.accrueYield(_amount);
    }

    function test_assetAuction_fullTakeBuildsLeverageNearTarget() public {
        uint256 amount = _testAmount();
        (uint256 available, uint256 idle) = _kickAssetAuction(amount);

        assertGt(available, idle, "!flashloan leg");

        uint256 oracleQuote = _oracleAssetToCollateral(available);
        uint256 auctionQuote = strategy.getAmountNeeded(
            address(asset),
            available
        );
        uint256 maxOracleQuote = (oracleQuote *
            (MAX_BPS + strategy.slippage())) / MAX_BPS;

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
        uint256 maxOracleQuote = (oracleQuote *
            (MAX_BPS + strategy.slippage())) / MAX_BPS;

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
        uint256 remainingNeed = strategy.getAmountNeeded(
            address(asset),
            remaining
        );
        _fundAndApprove(strategy.collateralToken(), secondTaker, remainingNeed);

        vm.prank(secondTaker);
        uint256 taken = strategy.take(
            address(asset),
            remaining,
            secondTaker,
            ""
        );

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
        assertLt(
            strategy.balanceOfCollateral(),
            collateralBefore,
            "!collateral"
        );
        assertLt(
            strategy.getCurrentLeverageRatio(),
            leverageBefore,
            "!leverage"
        );
    }

    function test_collateralAuction_partialTakesRepayDebtProRata() public {
        _buildLeveredPositionFromAssetAuction(_testAmount());

        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.25e18, 2.5e18);

        uint256 debtBefore = strategy.balanceOfDebt();
        uint256 totalDebtToRepay = _expectedDeleverDebtToRepay();
        assertGt(totalDebtToRepay, 0, "!debtToRepay");

        vm.prank(keeper);
        strategy.tend();

        address collateral = strategy.collateralToken();
        uint256 collateralAvailable = strategy.available(collateral);
        uint256 partialTake = collateralAvailable / 2;

        assertEq(strategy.activeAuction(), collateral, "!active auction");
        assertGt(partialTake, 0, "!partial");

        uint256 expectedFirstRepay = Math.mulDiv(
            totalDebtToRepay,
            partialTake,
            collateralAvailable
        );
        assertGt(expectedFirstRepay, 0, "!expectedFirstRepay");

        address firstDeleverTaker = makeAddr("first-delever-taker");
        _fundAndApprove(
            address(asset),
            firstDeleverTaker,
            strategy.getAmountNeeded(collateral, partialTake)
        );

        vm.prank(firstDeleverTaker);
        assertEq(
            strategy.take(collateral, partialTake, firstDeleverTaker, ""),
            partialTake,
            "!firstTaken"
        );

        uint256 debtAfterFirstTake = strategy.balanceOfDebt();

        assertEq(strategy.activeAuction(), collateral, "!auction still active");
        assertEq(
            strategy.available(collateral),
            collateralAvailable - partialTake,
            "!remaining collateral"
        );
        assertApproxEqAbs(
            debtBefore - debtAfterFirstTake,
            expectedFirstRepay,
            2,
            "!first repay"
        );

        uint256 remainingCollateral = strategy.available(collateral);
        uint256 expectedSecondRepay = totalDebtToRepay - expectedFirstRepay;

        address secondDeleverTaker = makeAddr("second-delever-taker");
        _fundAndApprove(
            address(asset),
            secondDeleverTaker,
            strategy.getAmountNeeded(collateral, remainingCollateral)
        );

        vm.prank(secondDeleverTaker);
        assertEq(
            strategy.take(
                collateral,
                remainingCollateral,
                secondDeleverTaker,
                ""
            ),
            remainingCollateral,
            "!secondTaken"
        );

        uint256 debtAfterSecondTake = strategy.balanceOfDebt();

        assertEq(strategy.activeAuction(), address(0), "!auction cleared");
        assertApproxEqAbs(
            debtAfterFirstTake - debtAfterSecondTake,
            expectedSecondRepay,
            2,
            "!second repay"
        );
        assertApproxEqAbs(
            debtBefore - debtAfterSecondTake,
            totalDebtToRepay,
            2,
            "!total repay"
        );
    }

    function _buildLeveredPositionFromAssetAuction(uint256 _amount) internal {
        (uint256 available, ) = _kickAssetAuction(_amount);

        address leverTaker = makeAddr("lever-taker");
        _fundAndApprove(
            strategy.collateralToken(),
            leverTaker,
            strategy.getAmountNeeded(address(asset), available)
        );

        vm.prank(leverTaker);
        strategy.take(address(asset), available, leverTaker, "");
    }

    function _expectedDeleverDebtToRepay() internal view returns (uint256) {
        uint256 currentDebt = strategy.balanceOfDebt();
        (uint256 collateralValue, ) = strategy.position();
        uint256 equity = collateralValue - currentDebt;
        uint256 targetCollateral = (equity * strategy.targetLeverageRatio()) /
            1e18;
        uint256 targetDebt = targetCollateral > equity
            ? targetCollateral - equity
            : 0;

        uint256 debtToRepay = currentDebt - targetDebt;
        debtToRepay = Math.min(debtToRepay, _maxFlashloan(address(asset)));

        uint256 maxSwap = strategy.maxAmountToSwap();
        if (maxSwap != type(uint256).max) {
            debtToRepay = Math.min(debtToRepay, maxSwap);
        }

        return debtToRepay;
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
        uint256 collateralPrice = oracle.getAssetPrice(
            strategy.collateralToken()
        );

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
        uint256 collateralPrice = oracle.getAssetPrice(
            strategy.collateralToken()
        );

        return
            (_collateralAmount * collateralPrice * (10 ** asset.decimals())) /
            (assetPrice * (10 ** ERC20(strategy.collateralToken()).decimals()));
    }

    function _testAmount() internal view returns (uint256) {
        uint256 min = minFuzzAmount;
        uint256 max = maxFuzzAmount;
        if (max <= min) return min;

        uint256 mid = (min + max) / 2;
        return mid > min ? mid : min;
    }

    /*//////////////////////////////////////////////////////////////
                    ASYNC AUCTION TESTS (TIME GAP BETWEEN KICK & TAKE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Asset auction taken after 5 minutes — price has decayed,
    ///         debt has accrued, taker gets a better deal than block-0.
    function test_assetAuction_asyncTake_5min() public {
        uint256 amount = _testAmount();
        (uint256 available, ) = _kickAssetAuction(amount);

        uint256 priceAtKick = strategy.price(address(asset));

        // Simulate realistic delay: 5 minutes (5 auction steps)
        skip(5 minutes);

        uint256 priceAfterDelay = strategy.price(address(asset));
        assertLt(priceAfterDelay, priceAtKick, "!price should decay");
        assertTrue(strategy.isActive(address(asset)), "!still active");

        uint256 auctionQuote = strategy.getAmountNeeded(
            address(asset),
            available
        );
        assertGt(auctionQuote, 0, "!quote");

        address taker = makeAddr("async-taker");
        _fundAndApprove(strategy.collateralToken(), taker, auctionQuote);

        vm.prank(taker);
        uint256 taken = strategy.take(address(asset), available, taker, "");

        assertEq(taken, available, "!taken");
        assertEq(strategy.activeAuction(), address(0), "!cleared");
        assertGt(strategy.balanceOfCollateral(), 0, "!collateral");
        assertGt(strategy.balanceOfDebt(), 0, "!debt");

        uint256 leverage = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGe(leverage, target - buffer, "!leverage low");
        assertLe(leverage, target + buffer, "!leverage high");
    }

    /// @notice Collateral auction taken after 10 minutes — verify debt
    ///         accrual between kick and take is handled correctly.
    function test_collateralAuction_asyncTake_10min() public {
        uint256 amount = _testAmount();
        _buildLeveredPositionFromAssetAuction(amount);

        // Push to over-leveraged so tend kicks a collateral auction
        vm.prank(management);
        strategy.setLeverageParams(2e18, 0.25e18, 2.5e18);

        uint256 debtBeforeTend = strategy.balanceOfDebt();

        vm.prank(keeper);
        strategy.tend();

        address collateral = strategy.collateralToken();
        assertEq(strategy.activeAuction(), collateral, "!active");
        uint256 collateralAvailable = strategy.available(collateral);
        assertGt(collateralAvailable, 0, "!available");

        // Simulate 10 minutes of delay — debt accrues on Aave
        skip(10 minutes);

        uint256 debtAfterDelay = strategy.balanceOfDebt();
        assertGe(debtAfterDelay, debtBeforeTend, "!debt should accrue");

        assertTrue(strategy.isActive(collateral), "!still active");

        uint256 auctionQuote = strategy.getAmountNeeded(
            collateral,
            collateralAvailable
        );
        assertGt(auctionQuote, 0, "!quote");

        address taker = makeAddr("async-delever-taker");
        _fundAndApprove(address(asset), taker, auctionQuote);

        vm.prank(taker);
        strategy.take(collateral, collateralAvailable, taker, "");

        assertEq(strategy.activeAuction(), address(0), "!cleared");
        assertLt(strategy.balanceOfDebt(), debtBeforeTend, "!debt reduced");
    }

    /// @notice Partial takes spread over time — first after 2 min, second
    ///         after another 5 min. Prices differ between takes.
    function test_assetAuction_asyncPartialTakes() public {
        uint256 amount = _testAmount();
        (uint256 available, ) = _kickAssetAuction(amount);

        uint256 firstTakeAmount = available / 3;
        assertGt(firstTakeAmount, 0, "!firstTakeAmount");

        // First take after 2 minutes
        skip(2 minutes);

        uint256 priceAt2Min = strategy.price(address(asset));

        address firstTaker = makeAddr("first-async-taker");
        uint256 firstQuote = strategy.getAmountNeeded(
            address(asset),
            firstTakeAmount
        );
        _fundAndApprove(strategy.collateralToken(), firstTaker, firstQuote);

        vm.prank(firstTaker);
        strategy.take(address(asset), firstTakeAmount, firstTaker, "");

        uint256 remainingAfterFirst = strategy.available(address(asset));
        assertEq(
            remainingAfterFirst,
            available - firstTakeAmount,
            "!remaining"
        );
        assertTrue(strategy.isActive(address(asset)), "!still active");

        // Second take after another 5 minutes (7 min total from kick)
        skip(5 minutes);

        uint256 priceAt7Min = strategy.price(address(asset));
        assertLt(priceAt7Min, priceAt2Min, "!price decayed further");

        address secondTaker = makeAddr("second-async-taker");
        uint256 secondQuote = strategy.getAmountNeeded(
            address(asset),
            remainingAfterFirst
        );
        _fundAndApprove(strategy.collateralToken(), secondTaker, secondQuote);

        vm.prank(secondTaker);
        strategy.take(address(asset), remainingAfterFirst, secondTaker, "");

        assertEq(strategy.activeAuction(), address(0), "!cleared");
        assertGt(strategy.balanceOfCollateral(), 0, "!collateral");
        assertGt(strategy.balanceOfDebt(), 0, "!debt");

        // Taker at 7 min paid less per unit than taker at 2 min
        uint256 pricePerUnit2Min = (firstQuote * 1e18) / firstTakeAmount;
        uint256 pricePerUnit7Min = (secondQuote * 1e18) / remainingAfterFirst;
        assertLt(pricePerUnit7Min, pricePerUnit2Min, "!later taker cheaper");
    }

    /// @notice Auction expires after AUCTION_LENGTH without being taken.
    ///         Verify it becomes inactive and a new tend can re-kick.
    function test_assetAuction_expiresAndReKick() public {
        uint256 amount = _testAmount();
        _kickAssetAuction(amount);

        assertTrue(strategy.isActive(address(asset)), "!active at start");

        // Skip past auction length
        skip(1 days + 1);

        assertFalse(strategy.isActive(address(asset)), "!should expire");
        assertEq(strategy.activeAuction(), address(0), "!no active auction");
        assertEq(strategy.available(address(asset)), 0, "!no available");

        // Settle the expired auction so a new one can be kicked
        vm.prank(emergencyAdmin);
        strategy.settle();

        // Re-tend should kick a fresh auction
        skip(strategy.minTendInterval() + 1);
        vm.prank(keeper);
        strategy.tend();

        assertTrue(strategy.isActive(address(asset)), "!re-kicked");
        assertGt(strategy.available(address(asset)), 0, "!new available");
    }

    /// @notice Full cycle: deposit → async lever → accrue yield →
    ///         report → async delever → withdraw.
    function test_fullCycle_asyncAuctions() public {
        uint256 amount = _testAmount();

        // 1. Deposit
        mintAndDepositIntoStrategy(strategy, user, amount);

        // 2. Tend kicks lever-up auction
        vm.prank(keeper);
        strategy.tend();
        assertEq(strategy.activeAuction(), address(asset), "!lever auction");

        // 3. Wait 3 minutes, then take (async lever)
        skip(3 minutes);
        _settleActiveAuction();

        uint256 leverageAfterBuild = strategy.getCurrentLeverageRatio();
        uint256 target = strategy.targetLeverageRatio();
        uint256 buffer = strategy.leverageBuffer();
        assertGe(leverageAfterBuild, target - buffer, "!lever low");
        assertLe(leverageAfterBuild, target + buffer, "!lever high");

        // 4. Accrue yield
        accrueYield(amount);

        // 5. Report — updates accounting with accrued debt/yield
        vm.prank(management);
        strategy.setLossLimitRatio(100);
        vm.prank(keeper);
        strategy.report();

        if (strategy.activeAuction() != address(0)) {
            skip(5 minutes);
            _settleActiveAuction();
        }

        // 6. Shutdown and unwind via async auction
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();
        vm.prank(emergencyAdmin);
        strategy.manualFullUnwind();

        skip(3 minutes);
        _settleActiveAuction();

        // 7. Unlock profits and redeem
        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore, "!redeemed");
    }
}
