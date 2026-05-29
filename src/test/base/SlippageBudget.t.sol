// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";

import {BaseLooper} from "../../BaseLooper.sol";
import {IExchange} from "../../interfaces/IExchange.sol";

contract MockFactory {
    function protocol_fee_config() external pure returns (uint16, address) {
        return (0, address(0));
    }
}

contract MockBudgetExchange is IExchange {
    uint256 internal constant MAX_BPS = 10_000;

    address public immutable asset;
    address public immutable collateral;

    uint256 public assetToCollateralBps = MAX_BPS;
    uint256 public collateralToAssetBps = MAX_BPS;

    constructor(address _asset, address _collateral) {
        asset = _asset;
        collateral = _collateral;
    }

    function name() external pure override returns (string memory) {
        return "MockBudgetExchange";
    }

    function setRates(
        uint256 _assetToCollateralBps,
        uint256 _collateralToAssetBps
    ) external {
        assetToCollateralBps = _assetToCollateralBps;
        collateralToAssetBps = _collateralToAssetBps;
    }

    function exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) external returns (uint256 amountOut) {
        if (from == asset && to == collateral) {
            ERC20Mock(asset).burn(msg.sender, amountIn);
            amountOut = (amountIn * assetToCollateralBps) / MAX_BPS;
            ERC20Mock(collateral).mint(msg.sender, amountOut);
        } else if (from == collateral && to == asset) {
            ERC20Mock(collateral).burn(msg.sender, amountIn);
            amountOut = (amountIn * collateralToAssetBps) / MAX_BPS;
            ERC20Mock(asset).mint(msg.sender, amountOut);
        } else {
            revert("bad pair");
        }

        require(amountOut >= amountOutMin, "!amountOut");
    }
}

contract MockBudgetLooper is BaseLooper {
    uint256 public collateralPrice = 1e36;

    uint256 public suppliedCollateral;
    uint256 public debt;
    uint256 public extraCollateralBalance;

    constructor(
        address _asset,
        address _collateral,
        address _exchange,
        address _governance
    )
        BaseLooper(
            _asset,
            "Mock Budget Looper",
            _collateral,
            _governance,
            _exchange
        )
    {}

    function swapAssetToCollateral(uint256 amount) external returns (uint256) {
        return _convertAssetToCollateral(amount);
    }

    function swapCollateralToAsset(uint256 amount) external returns (uint256) {
        return _convertCollateralToAsset(amount);
    }

    function setPosition(
        uint256 collateralAmount,
        uint256 debtAmount
    ) external {
        suppliedCollateral = collateralAmount;
        debt = debtAmount;
    }

    function withdrawAndSwapCollateral(
        uint256 amount
    ) external returns (uint256) {
        debt = amount > debt ? 0 : debt - amount;
        _withdrawCollateral(amount);
        return _convertCollateralToAsset(amount);
    }

    function updateLossLimit() external {
        _updateSlippageLossLimit();
    }

    function setExtraCollateralBalance(uint256 amount) external {
        extraCollateralBalance = amount;
    }

    function totalCollateralBalance() public view override returns (uint256) {
        return super.totalCollateralBalance() + extraCollateralBalance;
    }

    function _executeFlashloan(
        address,
        uint256,
        bytes memory
    ) internal pure override {
        revert("unused");
    }

    function maxFlashloan() public pure override returns (uint256) {
        return type(uint256).max;
    }

    function setCollateralPrice(uint256 _collateralPrice) external {
        collateralPrice = _collateralPrice;
    }

    function _getCollateralPrice() internal view override returns (uint256) {
        return collateralPrice;
    }

    function _supplyCollateral(uint256 amount) internal override {
        ERC20Mock(collateralToken).burn(address(this), amount);
        suppliedCollateral += amount;
    }

    function _withdrawCollateral(uint256 amount) internal override {
        suppliedCollateral -= amount;
        ERC20Mock(collateralToken).mint(address(this), amount);
    }

    function _borrow(uint256 amount) internal override {
        debt += amount;
        ERC20Mock(address(asset)).mint(address(this), amount);
    }

    function _repay(uint256 amount) internal override {
        uint256 repaid = amount > debt ? debt : amount;
        debt -= repaid;
        ERC20Mock(address(asset)).burn(address(this), repaid);
    }

    function _isSupplyPaused() internal pure override returns (bool) {
        return false;
    }

    function _isBorrowPaused() internal pure override returns (bool) {
        return false;
    }

    function _isLiquidatable() internal pure override returns (bool) {
        return false;
    }

    function _maxCollateralDeposit() internal pure override returns (uint256) {
        return type(uint256).max;
    }

    function _maxBorrowAmount() internal pure override returns (uint256) {
        return type(uint256).max;
    }

    function getLiquidateCollateralFactor()
        public
        pure
        override
        returns (uint256)
    {
        return 0.9e18;
    }

    function balanceOfCollateral() public view override returns (uint256) {
        return suppliedCollateral;
    }

    function balanceOfDebt() public view override returns (uint256) {
        return debt;
    }

    function _claimAndSellRewards() internal pure override {}
}

contract SlippageBudgetTest is Test {
    uint256 internal constant MAX_BPS = 10_000;
    address internal constant TOKENIZED_STRATEGY =
        0xD377919FA87120584B21279a491F82D5265A139c;

    ERC20Mock internal asset;
    ERC20Mock internal collateral;
    MockBudgetExchange internal exchange;
    MockBudgetLooper internal looper;

    function setUp() public {
        MockFactory factory = new MockFactory();
        TokenizedStrategy implementation = new TokenizedStrategy(
            address(factory)
        );
        vm.etch(TOKENIZED_STRATEGY, address(implementation).code);

        asset = new ERC20Mock();
        collateral = new ERC20Mock();
        exchange = new MockBudgetExchange(address(asset), address(collateral));
        looper = new MockBudgetLooper(
            address(asset),
            address(collateral),
            address(exchange),
            address(this)
        );

        // The first swap only opens a new accounting period when
        // block.timestamp >= slippagePeriodStart + SLIPPAGE_PERIOD. Foundry's
        // default block.timestamp of 1 leaves that branch dormant, so warp
        // past one full period before any test runs.
        vm.warp(block.timestamp + 1 days + 1);
    }

    function _depositTvlAndFundLoose(uint256 tvl, uint256 loose) internal {
        looper.setAllowed(address(this), true);
        asset.mint(address(this), tvl);
        asset.approve(address(looper), tvl);
        TokenizedStrategy(address(looper)).deposit(tvl, address(this));

        if (loose > 0) {
            asset.mint(address(looper), loose);
        }
    }

    function test_dailyLoss_zeroLossStartsPeriod() public {
        uint256 amount = 100_000;

        _depositTvlAndFundLoose(amount, 0);
        looper.setSlippage(10);
        exchange.setRates(MAX_BPS, MAX_BPS);

        uint256 amountOut = looper.swapAssetToCollateral(amount);

        assertEq(amountOut, amount, "wrong output");
        assertEq(looper.slippagePeriodStart(), block.timestamp, "wrong start");
        assertEq(looper.slippagePeriodLoss(), 0, "loss should stay zero");
    }

    function test_dailyLoss_accumulatesRealizedLossAcrossSwaps() public {
        uint256 amount = 100_000;

        _depositTvlAndFundLoose(amount, amount);
        looper.setSlippage(10);
        exchange.setRates(9_995, 9_995);

        looper.swapAssetToCollateral(amount);
        looper.swapAssetToCollateral(amount);

        assertEq(looper.slippagePeriodStart(), block.timestamp, "wrong start");
        assertEq(looper.slippagePeriodLoss(), 100, "wrong loss");
    }

    function test_dailyLoss_zeroLossChurnCanRunRepeatedly() public {
        uint256 tvl = 100_000;
        uint256 amount = 100_000;
        uint256 swaps = 8;

        _depositTvlAndFundLoose(tvl, amount * (swaps - 1));
        looper.setSlippage(10);
        exchange.setRates(MAX_BPS, MAX_BPS);

        for (uint256 i; i < swaps; i++) {
            looper.swapAssetToCollateral(amount);
        }

        assertEq(looper.slippagePeriodLoss(), 0, "loss");
    }

    function test_dailyLoss_revertsForBadPerTransactionSlippage() public {
        uint256 amount = 100_000;

        _depositTvlAndFundLoose(amount, 0);
        looper.setSlippage(10);
        exchange.setRates(9_989, 9_989);

        vm.expectRevert(bytes("!slippage"));
        looper.swapAssetToCollateral(amount);

        assertEq(looper.slippagePeriodLoss(), 0, "loss should revert");
    }

    function test_dailyLoss_revertsWhenDailyLossCapIsExceeded() public {
        uint256 amount = 100_000;

        _depositTvlAndFundLoose(amount, 0);
        looper.setLeverageParams(1e18, 0.01e18, 2e18);
        looper.setSlippage(10);
        exchange.setRates(9_990, 9_990);

        uint256 collateralOut = looper.swapAssetToCollateral(amount);

        vm.expectRevert(bytes("!slippage"));
        looper.swapCollateralToAsset(collateralOut);

        assertEq(looper.slippagePeriodLoss(), 100, "loss");
    }

    function test_dailyLoss_positiveSlippageDoesNotOffsetLoss() public {
        uint256 amount = 100_000;

        _depositTvlAndFundLoose(amount, amount);
        looper.setLeverageParams(1e18, 0.01e18, 2e18);
        looper.setSlippage(10);

        exchange.setRates(9_990, 9_990);
        looper.swapAssetToCollateral(amount);

        exchange.setRates(10_010, 10_010);
        uint256 amountOut = looper.swapCollateralToAsset(99_900);

        assertEq(looper.slippagePeriodLoss(), 100, "positive offset loss");
        assertEq(amountOut, 99_999, "wrong positive output");

        exchange.setRates(9_990, 9_990);
        vm.expectRevert(bytes("!slippage"));
        looper.swapAssetToCollateral(amountOut);

        assertEq(looper.slippagePeriodLoss(), 100, "loss should revert");
    }

    function test_dailyLoss_normalizesMixedDirectionsIntoAssetTerms() public {
        uint256 assetAmount = 100_000;
        uint256 collateralAmount = 50_000;

        looper.setCollateralPrice(2e36);
        _depositTvlAndFundLoose(assetAmount, 0);
        looper.setSlippage(6);

        collateral.mint(address(looper), collateralAmount);

        exchange.setRates(5_000, 20_000);
        looper.swapAssetToCollateral(assetAmount);

        exchange.setRates(5_000, 19_988);
        uint256 amountOut = looper.swapCollateralToAsset(collateralAmount);

        assertEq(amountOut, 99_940, "wrong output");
        assertEq(looper.slippagePeriodLoss(), 60, "wrong loss");
    }

    function test_dailyLoss_resetsAfterOneDay() public {
        uint256 amount = 100_000;

        _depositTvlAndFundLoose(amount, amount);
        looper.setSlippage(10);
        exchange.setRates(9_990, 9_990);

        looper.swapAssetToCollateral(amount);
        uint256 firstStart = looper.slippagePeriodStart();

        vm.warp(block.timestamp + 1 days + 1);

        looper.swapAssetToCollateral(amount);

        assertGt(looper.slippagePeriodStart(), firstStart, "start not reset");
        assertEq(looper.slippagePeriodLoss(), 100, "loss not reset");
    }

    function test_dailyLoss_tracksCollateralToAssetLoss() public {
        uint256 amount = 100_000;

        _depositTvlAndFundLoose(amount, 0);
        collateral.mint(address(looper), amount);
        looper.setSlippage(10);
        exchange.setRates(MAX_BPS, 9_995);

        uint256 amountOut = looper.swapCollateralToAsset(amount);

        assertEq(amountOut, 99_950, "wrong output");
        assertEq(looper.slippagePeriodLoss(), 50, "wrong loss");
    }

    function test_dailyLoss_zeroTargetWithoutCollateralExposureStartsAtOneTimesCap()
        public
    {
        uint256 amount = 100_000;

        _depositTvlAndFundLoose(amount, amount);
        looper.setSlippage(10);
        exchange.setRates(9_990, 9_990);

        looper.setLeverageParams(0, 0, 1e18);
        looper.swapAssetToCollateral(amount);

        assertEq(looper.slippagePeriodLossLimit(), 100, "loss limit");

        vm.expectRevert(bytes("!slippage"));
        looper.swapAssetToCollateral(amount);

        assertEq(looper.slippagePeriodLoss(), 100, "loss should revert");
    }

    function test_dailyLoss_usesPostSwapExposureForHighWaterLimit() public {
        uint256 amount = 100_000;

        _depositTvlAndFundLoose(amount, 0);
        looper.setSlippage(50);
        exchange.setRates(9_950, 9_950);

        looper.swapAssetToCollateral(amount);

        assertEq(looper.slippagePeriodLoss(), 500, "loss");
        assertEq(looper.slippagePeriodLossLimit(), 500, "loss limit");
    }

    function test_dailyLoss_usesTotalCollateralBalanceInSnapshot() public {
        _depositTvlAndFundLoose(100_000, 0);
        looper.setExtraCollateralBalance(300_000);
        looper.setSlippage(50);

        looper.updateLossLimit();

        assertEq(looper.slippagePeriodLossLimit(), 1_500, "loss limit");

        looper.setReportBuffer(1_000);
        assertEq(looper.estimatedTotalAssets(), 370_000, "report buffer");
    }

    function test_dailyLoss_usesActualExposureWhenTargetIsLowered() public {
        uint256 amount = 100_000;

        _depositTvlAndFundLoose(amount, 0);
        looper.setPosition(amount * 8, amount * 7);
        looper.setLeverageParams(0, 0, 1e18);
        looper.setSlippage(50);
        exchange.setRates(MAX_BPS, 9_950);

        looper.withdrawAndSwapCollateral(amount);
        looper.withdrawAndSwapCollateral(amount);

        assertEq(looper.slippagePeriodLoss(), 1_000, "loss");
        assertEq(looper.slippagePeriodLossLimit(), 4_000, "loss limit");
    }

    function test_dailyLoss_keepsHighWaterLimitWhenExposureShrinks() public {
        uint256 amount = 100_000;

        _depositTvlAndFundLoose(amount, 0);
        looper.setPosition(amount * 8, amount * 7);
        looper.setLeverageParams(0, 0, 1e18);
        looper.setSlippage(50);
        exchange.setRates(MAX_BPS, 9_950);

        for (uint256 i; i < 8; i++) {
            looper.withdrawAndSwapCollateral(amount);
        }

        assertEq(looper.balanceOfCollateral(), 0, "collateral");
        assertEq(looper.slippagePeriodLoss(), 4_000, "loss");
        assertEq(looper.slippagePeriodLossLimit(), 4_000, "loss limit");
    }

    function test_dailyLoss_resetsHighWaterLimitAfterOneDay() public {
        uint256 amount = 100_000;

        _depositTvlAndFundLoose(amount, 0);
        looper.setPosition(amount * 8, amount * 7);
        looper.setLeverageParams(0, 0, 1e18);
        looper.setSlippage(50);
        exchange.setRates(MAX_BPS, 9_950);

        looper.withdrawAndSwapCollateral(amount);
        assertEq(looper.slippagePeriodLossLimit(), 4_000, "first limit");

        vm.warp(block.timestamp + 1 days + 1);
        looper.setPosition(amount, 0);
        looper.withdrawAndSwapCollateral(amount);

        assertEq(looper.slippagePeriodLoss(), 500, "loss");
        assertEq(looper.slippagePeriodLossLimit(), 500, "reset limit");
    }
}
