// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {IExchange} from "../../interfaces/IExchange.sol";
import {ERC4626UniswapExchange} from "../../periphery/ERC4626UniswapExchange.sol";

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

contract MockERC4626UniswapExchange is ERC4626UniswapExchange {
    uint256 public swapCalls;
    uint256 public nextSwapOut;

    constructor(
        address _weth,
        address _base,
        address _asset,
        address _collateral
    ) ERC4626UniswapExchange(_weth, _base, _asset, _collateral) {}

    function setNextSwapOut(uint256 amountOut) external {
        nextSwapOut = amountOut;
    }

    function _swapFrom(
        address,
        address to,
        uint256 amountIn,
        uint256
    ) internal override returns (uint256 amountOut) {
        swapCalls += 1;
        amountOut = nextSwapOut == 0 ? amountIn : nextSwapOut;
        IMintableToken(to).mint(address(this), amountOut);
    }
}

contract ERC4626UniswapExchangeTest is Test {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    MockERC20 internal asset;
    MockERC20 internal baseToken;
    MockERC20 internal underlying;
    MockVault internal collateral;

    MockERC4626UniswapExchange internal exchange;
    MockStrategyForExchange internal strategy;

    address internal governance = makeAddr("governance");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        asset = new MockERC20("Asset", "AST");
        baseToken = new MockERC20("Base", "BSE");
        underlying = new MockERC20("Underlying", "UND");
        collateral = new MockVault(underlying);

        exchange = new MockERC4626UniswapExchange(
            WETH,
            address(baseToken),
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
        strategy.approveToken(
            address(underlying),
            address(exchange),
            type(uint256).max
        );
    }

    function test_constructor_setsCoreConfig() public view {
        assertEq(exchange.ASSET(), address(asset), "!asset");
        assertEq(exchange.COLLATERAL(), address(collateral), "!collateral");
        assertEq(exchange.UNDERLYING(), address(underlying), "!underlying");
        assertEq(exchange.base(), address(baseToken), "!base");
        assertFalse(exchange.deposit(), "!deposit");
        assertFalse(exchange.redeem(), "!redeem");
    }

    function test_setters_onlyManagement() public {
        vm.startPrank(stranger);
        vm.expectRevert("!management");
        exchange.setDeposit(true);

        vm.expectRevert("!management");
        exchange.setRedeem(true);

        vm.expectRevert("!management");
        exchange.setBase(address(asset));

        vm.expectRevert("!management");
        exchange.setUniFees(address(asset), address(baseToken), 500);

        vm.expectRevert("!management");
        exchange.setV4Pool(
            address(asset),
            address(baseToken),
            bytes32(uint256(123))
        );
        vm.stopPrank();

        exchange.setDeposit(true);
        exchange.setDeposit(false);
        exchange.setRedeem(true);
        exchange.setBase(address(asset));
        exchange.setUniFees(address(asset), address(baseToken), 500);

        vm.mockCall(
            exchange.positionManager(),
            abi.encodeWithSignature(
                "poolKeys(bytes25)",
                bytes25(bytes32(uint256(123)))
            ),
            abi.encode(
                address(asset),
                address(baseToken),
                uint24(3000),
                int24(60),
                address(0x9999)
            )
        );
        exchange.setV4Pool(
            address(asset),
            address(baseToken),
            bytes32(uint256(123))
        );

        assertFalse(exchange.deposit(), "!deposit");
        assertTrue(exchange.redeem(), "!redeem");
        assertEq(exchange.base(), address(asset), "!base");
        assertEq(
            exchange.uniFees(address(asset), address(baseToken)),
            500,
            "!fee"
        );
        (uint24 fee, int24 tickSpacing, address hooks) = exchange.v4Pools(
            address(asset),
            address(baseToken)
        );
        assertEq(fee, 3000, "!fee");
        assertEq(tickSpacing, 60, "!tickSpacing");
        assertEq(hooks, address(0x9999), "!hooks");
    }

    function test_exchange_assetToCollateral_usesDepositWhenEnabled() public {
        exchange.setDeposit(true);
        exchange.setNextSwapOut(80e18);
        asset.mint(address(strategy), 100e18);

        uint256 amountOut = strategy.swap(
            address(asset),
            address(collateral),
            100e18,
            0
        );

        assertEq(amountOut, 80e18, "!amountOut");
        assertEq(collateral.balanceOf(address(strategy)), 80e18, "!shares");
        assertEq(exchange.swapCalls(), 1, "!swapCalls");
    }

    function test_exchange_collateralToUnderlying_usesRedeemWhenEnabled()
        public
    {
        exchange.setDeposit(true);
        underlying.mint(address(strategy), 100e18);
        strategy.swap(address(underlying), address(collateral), 100e18, 0);

        exchange.setRedeem(true);
        uint256 amountOut = strategy.swap(
            address(collateral),
            address(underlying),
            100e18,
            0
        );

        assertEq(amountOut, 100e18, "!amountOut");
        assertEq(
            underlying.balanceOf(address(strategy)),
            100e18,
            "!underlying"
        );
    }

    function test_exchange_collateralToAsset_usesRedeemWhenEnabled() public {
        exchange.setDeposit(true);
        underlying.mint(address(strategy), 100e18);
        strategy.swap(address(underlying), address(collateral), 100e18, 0);

        exchange.setRedeem(true);
        exchange.setNextSwapOut(75e18);

        uint256 amountOut = strategy.swap(
            address(collateral),
            address(asset),
            100e18,
            0
        );

        assertEq(amountOut, 75e18, "!amountOut");
        assertEq(asset.balanceOf(address(strategy)), 75e18, "!asset");
        assertEq(exchange.swapCalls(), 1, "!swapCalls");
    }

    function test_exchange_marketPathStillWorksWhenVaultRoutesDisabled()
        public
    {
        exchange.setNextSwapOut(42e18);
        asset.mint(address(strategy), 100e18);

        uint256 amountOut = strategy.swap(
            address(asset),
            address(collateral),
            100e18,
            0
        );

        assertEq(amountOut, 42e18, "!amountOut");
        assertEq(collateral.balanceOf(address(strategy)), 42e18, "!shares");
        assertEq(exchange.swapCalls(), 1, "!swapCalls");
    }
}
