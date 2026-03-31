// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {IExchange} from "../../interfaces/IExchange.sol";
import {SyrupExchange} from "../../periphery/SyrupExchange.sol";
import {ISyrupRouter} from "../../interfaces/syrup/ISyrupRouter.sol";

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

interface IMintableShares {
    function mintShares(address to, uint256 amount) external;
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

contract MockSyrupVault is ERC4626 {
    constructor(ERC20 asset_) ERC20("Mock Syrup", "mSYRUP") ERC4626(asset_) {}

    function mintShares(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPoolPermissionManager {
    bool public allowed;

    function setAllowed(bool _allowed) external {
        allowed = _allowed;
    }

    function hasPermission(
        address,
        address,
        bytes32
    ) external view returns (bool hasPermission_) {
        return allowed;
    }
}

contract MockSyrupRouter is ISyrupRouter {
    ERC20 public immutable asset;
    MockSyrupVault public immutable collateral;
    MockPoolPermissionManager public immutable permissionManager;
    address public immutable manager;

    uint256 public depositCalls;
    uint256 public authorizeAndDepositCalls;
    uint256 public lastAmount;
    bytes32 public lastDepositData;
    uint256 public lastDeadline;
    uint8 public lastV;
    bytes32 public lastR;
    bytes32 public lastS;

    constructor(
        address _asset,
        address _collateral,
        address _permissionManager,
        address _manager
    ) {
        asset = ERC20(_asset);
        collateral = MockSyrupVault(_collateral);
        permissionManager = MockPoolPermissionManager(_permissionManager);
        manager = _manager;
    }

    function poolManager() external view returns (address) {
        return manager;
    }

    function poolPermissionManager() external view returns (address) {
        return address(permissionManager);
    }

    function deposit(
        uint256 amount,
        bytes32 depositData
    ) external returns (uint256 amountOut) {
        require(permissionManager.allowed(), "SR:D:NOT_AUTHORIZED");

        depositCalls += 1;
        lastAmount = amount;
        lastDepositData = depositData;

        asset.transferFrom(msg.sender, address(this), amount);
        collateral.mintShares(msg.sender, amount);

        return amount;
    }

    function authorizeAndDeposit(
        uint256 amount,
        bytes32 depositData,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountOut) {
        authorizeAndDepositCalls += 1;
        lastDeadline = deadline;
        lastV = v;
        lastR = r;
        lastS = s;

        permissionManager.setAllowed(true);
        depositCalls += 1;
        lastAmount = amount;
        lastDepositData = depositData;

        asset.transferFrom(msg.sender, address(this), amount);
        collateral.mintShares(msg.sender, amount);

        return amount;
    }
}

contract MockStrategyForSyrupExchange {
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

contract MockSyrupExchange is SyrupExchange {
    uint256 public swapCalls;
    uint256 public nextSwapOut;

    constructor(
        address weth,
        address asset,
        address collateral,
        address router
    ) SyrupExchange(weth, asset, collateral, router) {}

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

        if (to == COLLATERAL) {
            IMintableShares(to).mintShares(address(this), amountOut);
        } else {
            IMintableERC20(to).mint(address(this), amountOut);
        }
    }
}

contract SyrupExchangeTest is Test {
    MockERC20 internal asset;
    MockSyrupVault internal collateral;
    MockSyrupRouter internal syrupRouter;
    MockPoolPermissionManager internal permissionManager;
    MockSyrupExchange internal exchange;
    MockStrategyForSyrupExchange internal strategy;

    address internal governance = makeAddr("governance");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        asset = new MockERC20("Asset", "AST");
        collateral = new MockSyrupVault(asset);
        permissionManager = new MockPoolPermissionManager();
        permissionManager.setAllowed(true);
        syrupRouter = new MockSyrupRouter(
            address(asset),
            address(collateral),
            address(permissionManager),
            makeAddr("poolManager")
        );

        exchange = new MockSyrupExchange(
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            address(asset),
            address(collateral),
            address(syrupRouter)
        );
        strategy = new MockStrategyForSyrupExchange(address(this), governance);

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
    }

    function test_constructor_revertsWhenCollateralAssetMismatch() public {
        MockERC20 otherAsset = new MockERC20("Other", "OTH");
        MockSyrupVault wrongCollateral = new MockSyrupVault(otherAsset);

        vm.expectRevert("!asset");
        new MockSyrupExchange(
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            address(asset),
            address(wrongCollateral),
            address(syrupRouter)
        );
    }

    function test_constructor_revertsWhenRouterZero() public {
        vm.expectRevert("!router");
        new MockSyrupExchange(
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            address(asset),
            address(collateral),
            address(0)
        );
    }

    function test_setMint_onlyManagement() public {
        vm.prank(stranger);
        vm.expectRevert("!management");
        exchange.setMint(true);

        exchange.setMint(true);
        assertTrue(exchange.mint(), "!mint");
    }

    function test_authorizeAndDeposit_onlyManagement() public {
        asset.mint(address(exchange), 100e18);

        vm.prank(stranger);
        vm.expectRevert("!management");
        exchange.authorizeAndDeposit(
            100e18,
            block.timestamp + 1 days,
            27,
            bytes32(uint256(1)),
            bytes32(uint256(2))
        );

        uint256 amountOut = exchange.authorizeAndDeposit(
            100e18,
            block.timestamp + 1 days,
            27,
            bytes32(uint256(1)),
            bytes32(uint256(2))
        );

        assertEq(amountOut, 100e18, "!amountOut");
        assertEq(syrupRouter.authorizeAndDepositCalls(), 1, "!auth calls");
        assertEq(syrupRouter.depositCalls(), 1, "!deposit calls");
        assertEq(syrupRouter.lastDepositData(), bytes32("Yearn"), "!data");
        assertEq(
            syrupRouter.lastDeadline(),
            block.timestamp + 1 days,
            "!deadline"
        );
    }

    function test_constructor_setsRouter() public view {
        assertEq(exchange.SYRUP_ROUTER(), address(syrupRouter), "!router");
    }

    function test_exchange_assetToCollateral_usesDepositWhenMintEnabled()
        public
    {
        exchange.setMint(true);
        asset.mint(address(strategy), 100e18);

        uint256 amountOut = strategy.swap(
            address(asset),
            address(collateral),
            100e18,
            0
        );

        assertEq(amountOut, 100e18, "!amountOut");
        assertEq(collateral.balanceOf(address(strategy)), 100e18, "!shares");
        assertEq(asset.balanceOf(address(strategy)), 0, "!asset");
        assertEq(exchange.swapCalls(), 0, "!swapCalls");
        assertEq(syrupRouter.depositCalls(), 1, "!router calls");
        assertEq(syrupRouter.lastAmount(), 100e18, "!router amount");
        assertEq(
            syrupRouter.lastDepositData(),
            bytes32("Yearn"),
            "!depositData"
        );
    }

    function test_exchange_assetToCollateral_usesSwapWhenMintDisabled() public {
        exchange.setMint(false);
        exchange.setNextSwapOut(123e18);
        asset.mint(address(strategy), 100e18);

        uint256 amountOut = strategy.swap(
            address(asset),
            address(collateral),
            100e18,
            0
        );

        assertEq(amountOut, 123e18, "!amountOut");
        assertEq(collateral.balanceOf(address(strategy)), 123e18, "!shares");
        assertEq(exchange.swapCalls(), 1, "!swapCalls");
        assertEq(syrupRouter.depositCalls(), 0, "!router calls");
    }

    function test_exchange_assetToCollateral_revertsWhenNotAuthorized() public {
        exchange.setMint(true);
        permissionManager.setAllowed(false);
        asset.mint(address(strategy), 100e18);

        vm.expectRevert("SR:D:NOT_AUTHORIZED");
        strategy.swap(address(asset), address(collateral), 100e18, 0);
    }

    function test_exchange_assetToCollateral_worksAfterManagementAuthorizeAndDeposit()
        public
    {
        exchange.setMint(true);
        permissionManager.setAllowed(false);

        asset.mint(address(exchange), 1e18);
        exchange.authorizeAndDeposit(
            1e18,
            block.timestamp + 1 days,
            27,
            bytes32(uint256(111)),
            bytes32(uint256(222))
        );

        asset.mint(address(strategy), 100e18);
        uint256 amountOut = strategy.swap(
            address(asset),
            address(collateral),
            100e18,
            0
        );

        assertEq(amountOut, 100e18, "!amountOut");
        assertEq(syrupRouter.authorizeAndDepositCalls(), 1, "!auth calls");
        assertEq(syrupRouter.depositCalls(), 2, "!deposit calls");
    }

    function test_exchange_collateralToAsset_usesSwapEvenWhenMintEnabled()
        public
    {
        exchange.setMint(true);
        exchange.setNextSwapOut(88e18);
        collateral.mintShares(address(strategy), 50e18);

        uint256 amountOut = strategy.swap(
            address(collateral),
            address(asset),
            50e18,
            0
        );

        assertEq(amountOut, 88e18, "!amountOut");
        assertEq(asset.balanceOf(address(strategy)), 88e18, "!assetOut");
        assertEq(exchange.swapCalls(), 1, "!swapCalls");
        assertEq(syrupRouter.depositCalls(), 0, "!router calls");
    }
}
