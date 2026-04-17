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
    uint256 internal constant PRICE = 1e36;

    uint256 public suppliedCollateral;
    uint256 public debt;

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

    function _getCollateralPrice() internal pure override returns (uint256) {
        return PRICE;
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
        vm.warp(1 days + 1);

        asset = new ERC20Mock();
        collateral = new ERC20Mock();
        exchange = new MockBudgetExchange(address(asset), address(collateral));
        looper = new MockBudgetLooper(
            address(asset),
            address(collateral),
            address(exchange),
            address(this)
        );
    }

    function test_dailyBudget_zeroLossDoesNotConsumeBudget() public {
        uint256 amount = 100_000;

        asset.mint(address(looper), amount);
        looper.setSlippage(10);
        exchange.setRates(MAX_BPS, MAX_BPS);

        uint256 amountOut = looper.swapAssetToCollateral(amount);

        assertEq(amountOut, amount, "wrong output");
        assertEq(looper.slippagePeriodStart(), 0, "start should stay unset");
        assertEq(looper.realizedSlippage(), 0, "slippage should stay zero");
    }

    function test_dailyBudget_accumulatesLossAcrossSwaps() public {
        uint256 amount = 100_000;

        asset.mint(address(looper), amount * 2);
        looper.setSlippage(10);
        exchange.setRates(9_995, 9_995);

        uint256 start = block.timestamp;
        looper.swapAssetToCollateral(amount);
        looper.swapAssetToCollateral(amount);

        assertEq(looper.slippagePeriodStart(), start, "wrong start");
        assertEq(looper.realizedSlippage(), 10, "wrong slippage");
    }

    function test_dailyBudget_revertsWhenCumulativeBudgetIsExceeded() public {
        uint256 amount = 100_000;

        asset.mint(address(looper), amount * 2);
        looper.setSlippage(10);

        exchange.setRates(9_995, 9_995);
        looper.swapAssetToCollateral(amount);

        exchange.setRates(9_980, 9_980);
        vm.expectRevert(bytes("!slippage"));
        looper.swapAssetToCollateral(amount);
    }

    function test_dailyBudget_resetsAfterOneDay() public {
        uint256 amount = 100_000;

        asset.mint(address(looper), amount * 2);
        looper.setSlippage(10);
        exchange.setRates(9_995, 9_995);

        looper.swapAssetToCollateral(amount);
        uint256 firstStart = looper.slippagePeriodStart();

        vm.warp(block.timestamp + 1 days + 1);

        looper.swapAssetToCollateral(amount);

        assertGt(looper.slippagePeriodStart(), firstStart, "start not reset");
        assertEq(looper.realizedSlippage(), 5, "slippage not reset");
    }

    function test_dailyBudget_tracksCollateralToAssetLoss() public {
        uint256 amount = 100_000;

        collateral.mint(address(looper), amount);
        looper.setSlippage(10);
        exchange.setRates(MAX_BPS, 9_995);

        uint256 amountOut = looper.swapCollateralToAsset(amount);

        assertEq(amountOut, 99_950, "wrong output");
        assertEq(looper.realizedSlippage(), 5, "wrong slippage");
    }

    function test_dailyBudget_revertsForCollateralToAssetWhenLimitIsExceeded()
        public
    {
        uint256 amount = 100_000;

        collateral.mint(address(looper), amount * 2);
        looper.setSlippage(10);
        exchange.setRates(9_995, 9_995);

        looper.swapCollateralToAsset(amount);

        exchange.setRates(9_980, 9_980);
        vm.expectRevert(bytes("!slippage"));
        looper.swapCollateralToAsset(amount);
    }
}
