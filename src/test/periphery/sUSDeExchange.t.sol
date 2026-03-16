// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {IExchange} from "../../interfaces/IExchange.sol";
import {sUSDeExchange} from "../../periphery/sUSDeExchange.sol";
import {IFluidDexT1} from "@periphery/interfaces/Fluid/IFluidDexV2Router.sol";

interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

contract MockERC20 is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVault is ERC4626 {
    constructor(ERC20 asset_) ERC20("Mock Vault", "mVAULT") ERC4626(asset_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFluidDex is IFluidDexT1 {
    ConstantViews internal _constants;

    uint256 public rate0To1 = 1e18;
    uint256 public rate1To0 = 1e18;
    uint256 public swapCalls;

    constructor(address token0_, address token1_) {
        _constants.token0 = token0_;
        _constants.token1 = token1_;
    }

    function setRate0To1(uint256 rate) external {
        rate0To1 = rate;
    }

    function setRate1To0(uint256 rate) external {
        rate1To0 = rate;
    }

    function constantsView()
        external
        view
        returns (ConstantViews memory constantsView_)
    {
        return _constants;
    }

    function swapIn(
        bool swap0to1_,
        uint256 amountIn_,
        uint256 amountOutMin_,
        address to_
    ) external payable returns (uint256 amountOut_) {
        swapCalls += 1;

        address tokenIn = swap0to1_ ? _constants.token0 : _constants.token1;
        address tokenOut = swap0to1_ ? _constants.token1 : _constants.token0;
        uint256 rate = swap0to1_ ? rate0To1 : rate1To0;

        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn_);

        amountOut_ = (amountIn_ * rate) / 1e18;
        require(amountOut_ >= amountOutMin_, "!min");

        IMintableToken(tokenOut).mint(to_, amountOut_);
    }
}

contract MockStrategyForExchange {
    address public management;
    address public GOVERNANCE;
    IExchange public exchange;

    constructor(address _management, address _governance) {
        management = _management;
        GOVERNANCE = _governance;
    }

    function setExchange(address _exchange) external {
        exchange = IExchange(_exchange);
    }

    function approveToken(
        address token,
        address spender,
        uint256 amount
    ) external {
        ERC20(token).approve(spender, amount);
    }

    function swap(
        address from,
        address to,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        return exchange.exchange(from, to, amountIn, minAmountOut);
    }
}

contract sUSDeExchangeTest is Test {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    MockERC20 internal asset;
    MockERC20 internal bridge;
    MockERC20 internal underlying;
    MockVault internal collateral;

    MockFluidDex internal assetBridgeDex;
    MockFluidDex internal underlyingBridgeDex;
    MockFluidDex internal collateralBridgeDex;

    sUSDeExchange internal exchange;
    MockStrategyForExchange internal strategy;

    address internal governance = makeAddr("governance");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        asset = new MockERC20("Asset", "AST");
        bridge = new MockERC20("Bridge", "BRG");
        underlying = new MockERC20("Underlying", "UND");
        collateral = new MockVault(underlying);

        assetBridgeDex = new MockFluidDex(address(asset), address(bridge));
        underlyingBridgeDex = new MockFluidDex(
            address(underlying),
            address(bridge)
        );
        collateralBridgeDex = new MockFluidDex(
            address(collateral),
            address(bridge)
        );

        exchange = new sUSDeExchange(
            WETH,
            address(bridge),
            address(asset),
            address(collateral)
        );
        strategy = new MockStrategyForExchange(address(this), governance);

        exchange.setStrategy(address(strategy));
        strategy.setExchange(address(exchange));

        strategy.approveToken(
            address(asset),
            address(exchange),
            type(uint256).max
        );
        strategy.approveToken(
            address(collateral),
            address(exchange),
            type(uint256).max
        );

        exchange.setFluidDex(
            address(asset),
            address(bridge),
            address(assetBridgeDex)
        );
        exchange.setFluidDex(
            address(underlying),
            address(bridge),
            address(underlyingBridgeDex)
        );
        exchange.setFluidDex(
            address(collateral),
            address(bridge),
            address(collateralBridgeDex)
        );
    }

    function test_constructor_setsCoreConfig() public view {
        assertEq(exchange.ASSET(), address(asset), "!asset");
        assertEq(exchange.COLLATERAL(), address(collateral), "!collateral");
        assertEq(exchange.UNDERLYING(), address(underlying), "!underlying");
        assertEq(exchange.base(), address(bridge), "!base");
    }

    function test_setters_onlyManagement() public {
        vm.prank(stranger);
        vm.expectRevert("!management");
        exchange.setMint(true);

        vm.prank(stranger);
        vm.expectRevert("!management");
        exchange.setBase(address(asset));

        vm.prank(stranger);
        vm.expectRevert("!management");
        exchange.setMinAmountToSell(1e18);

        exchange.setMint(true);
        exchange.setBase(address(asset));
        exchange.setMinAmountToSell(1e18);

        assertTrue(exchange.mint(), "!mint");
        assertEq(exchange.base(), address(asset), "!base");
        assertEq(exchange.minAmountToSell(), 1e18, "!min");
    }

    function test_exchange_assetToCollateral_usesDepositWhenMintEnabled()
        public
    {
        exchange.setMint(true);
        assetBridgeDex.setRate0To1(0.9e18);
        underlyingBridgeDex.setRate1To0(0.8e18);

        asset.mint(address(strategy), 100e18);

        uint256 amountOut = strategy.swap(
            address(asset),
            address(collateral),
            100e18,
            0
        );

        assertEq(amountOut, 72e18, "!amountOut");
        assertEq(collateral.balanceOf(address(strategy)), 72e18, "!shares");
        assertEq(assetBridgeDex.swapCalls(), 1, "!asset bridge calls");
        assertEq(
            underlyingBridgeDex.swapCalls(),
            1,
            "!underlying bridge calls"
        );
        assertEq(
            collateralBridgeDex.swapCalls(),
            0,
            "!collateral bridge calls"
        );
    }

    function test_exchange_assetToCollateral_usesMarketWhenMintDisabled()
        public
    {
        assetBridgeDex.setRate0To1(0.9e18);
        collateralBridgeDex.setRate1To0(0.5e18);

        asset.mint(address(strategy), 100e18);

        uint256 amountOut = strategy.swap(
            address(asset),
            address(collateral),
            100e18,
            0
        );

        assertEq(amountOut, 45e18, "!amountOut");
        assertEq(collateral.balanceOf(address(strategy)), 45e18, "!shares");
        assertEq(assetBridgeDex.swapCalls(), 1, "!asset bridge calls");
        assertEq(
            underlyingBridgeDex.swapCalls(),
            0,
            "!underlying bridge calls"
        );
        assertEq(
            collateralBridgeDex.swapCalls(),
            1,
            "!collateral bridge calls"
        );
    }

    function test_exchange_collateralToAsset_usesMarketLiquidity() public {
        exchange.setMint(true);
        collateralBridgeDex.setRate0To1(0.5e18);
        assetBridgeDex.setRate1To0(0.8e18);

        collateral.mint(address(strategy), 100e18);

        uint256 amountOut = strategy.swap(
            address(collateral),
            address(asset),
            100e18,
            0
        );

        assertEq(amountOut, 40e18, "!amountOut");
        assertEq(asset.balanceOf(address(strategy)), 40e18, "!assetOut");
        assertEq(assetBridgeDex.swapCalls(), 1, "!asset bridge calls");
        assertEq(
            underlyingBridgeDex.swapCalls(),
            0,
            "!underlying bridge calls"
        );
        assertEq(
            collateralBridgeDex.swapCalls(),
            1,
            "!collateral bridge calls"
        );
    }

    function test_exchange_mintPathRespectsFinalMinAmountOut() public {
        exchange.setMint(true);
        assetBridgeDex.setRate0To1(0.9e18);
        underlyingBridgeDex.setRate1To0(0.8e18);

        asset.mint(address(strategy), 100e18);

        vm.expectRevert("!amountOut");
        strategy.swap(address(asset), address(collateral), 100e18, 73e18);
    }
}
