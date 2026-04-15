// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {IExchange} from "../../interfaces/IExchange.sol";
import {ISyrupRouter} from "../../interfaces/syrup/ISyrupRouter.sol";
import {MetaExchange} from "../../periphery/MetaExchange.sol";

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

contract MockERC20Decimals is ERC20 {
    uint8 internal immutable tokenDecimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockWETH is MockERC20Decimals {
    constructor() MockERC20Decimals("Wrapped Ether", "WETH", 18) {}

    receive() external payable {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
}

contract MockLitePSM {
    MockERC20Decimals public immutable gem;
    MockERC20Decimals public immutable usds;
    uint256 public immutable scale;

    constructor(
        MockERC20Decimals gem_,
        MockERC20Decimals usds_,
        uint256 scale_
    ) {
        gem = gem_;
        usds = usds_;
        scale = scale_;
    }

    function sellGem(
        address usr,
        uint256 gemAmt
    ) external returns (uint256 usdsOut) {
        require(gem.transferFrom(msg.sender, address(this), gemAmt), "!gem");
        usdsOut = gemAmt * scale;
        usds.mint(usr, usdsOut);
    }

    function buyGem(
        address usr,
        uint256 gemAmt
    ) external returns (uint256 usdsIn) {
        usdsIn = gemAmt * scale;
        require(usds.transferFrom(msg.sender, address(this), usdsIn), "!usds");
        gem.mint(usr, gemAmt);
    }
}

contract MockVault is ERC4626 {
    constructor(ERC20 asset_) ERC20("Mock Vault", "mVAULT") ERC4626(asset_) {}
}

contract MockSyrupVault is ERC4626 {
    constructor(ERC20 asset_) ERC20("Mock Syrup", "mSYRUP") ERC4626(asset_) {}

    function mintShares(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSyrupRouter is ISyrupRouter {
    ERC20 public immutable asset;
    MockSyrupVault public immutable vault;

    uint256 public depositCalls;
    uint256 public lastAmount;
    bytes32 public lastDepositData;

    constructor(address asset_, address vault_) {
        asset = ERC20(asset_);
        vault = MockSyrupVault(vault_);
    }

    function poolManager() external pure returns (address) {
        return address(0);
    }

    function poolPermissionManager() external pure returns (address) {
        return address(0);
    }

    function deposit(
        uint256 amount,
        bytes32 depositData
    ) external returns (uint256 amountOut) {
        depositCalls += 1;
        lastAmount = amount;
        lastDepositData = depositData;

        asset.transferFrom(msg.sender, address(this), amount);
        vault.mintShares(msg.sender, amount);
        return amount;
    }

    function authorizeAndDeposit(
        uint256,
        bytes32,
        uint256,
        uint8,
        bytes32,
        bytes32
    ) external pure returns (uint256) {
        revert("!unused");
    }
}

contract MockSUSDSVault is ERC4626 {
    uint16 public lastReferral;
    uint256 public lastAssets;
    address public lastReceiver;

    constructor(ERC20 asset_) ERC20("Mock sUSDS", "msUSDS") ERC4626(asset_) {}

    function deposit(
        uint256 assets,
        address receiver,
        uint16 referral
    ) external returns (uint256 shares) {
        lastAssets = assets;
        lastReceiver = receiver;
        lastReferral = referral;
        shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
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

contract MockMetaExchange is MetaExchange {
    mapping(uint256 => uint256) public callCounts;
    address internal immutable mockLitePsmGem;
    address internal immutable mockLitePsmUsds;
    address internal immutable mockLitePsmWrapper;
    uint256 internal immutable mockLitePsmScale;

    constructor(
        address weth,
        address litePsmGem,
        address litePsmUsds,
        address litePsmWrapper,
        uint256 litePsmScale
    ) MetaExchange(weth) {
        mockLitePsmGem = litePsmGem;
        mockLitePsmUsds = litePsmUsds;
        mockLitePsmWrapper = litePsmWrapper;
        mockLitePsmScale = litePsmScale;
    }

    function _swapStep(
        Venue venue,
        address from,
        address to,
        uint256 amountIn
    ) internal override returns (uint256 amountOut) {
        if (
            venue == Venue.ERC4626_DEPOSIT ||
            venue == Venue.ERC4626_REDEEM ||
            venue == Venue.LITE_PSM ||
            venue == Venue.WRAPPED_NATIVE ||
            venue == Venue.SYRUP_DEPOSIT ||
            venue == Venue.SUSDS_DEPOSIT
        ) {
            return super._swapStep(venue, from, to, amountIn);
        }

        callCounts[uint256(venue)] += 1;
        require(ERC20(from).transfer(address(0xdead), amountIn), "!fromSpend");
        amountOut = amountIn;
        IMintableToken(to).mint(address(this), amountOut);
    }

    function _litePsmSwap(
        address from,
        address to,
        uint256 amountIn
    ) internal override returns (uint256 amountOut) {
        if (from == mockLitePsmGem && to == mockLitePsmUsds) {
            _checkAllowance(mockLitePsmWrapper, from, amountIn);
            return
                MockLitePSM(mockLitePsmWrapper).sellGem(
                    address(this),
                    amountIn
                );
        }

        require(from == mockLitePsmUsds && to == mockLitePsmGem, "!psm");

        uint256 gemAmount = amountIn / mockLitePsmScale;
        require(gemAmount != 0, "!amountOut");

        _checkAllowance(mockLitePsmWrapper, from, amountIn);

        uint256 balanceBefore = ERC20(to).balanceOf(address(this));
        MockLitePSM(mockLitePsmWrapper).buyGem(address(this), gemAmount);
        amountOut = ERC20(to).balanceOf(address(this)) - balanceBefore;
        require(amountOut != 0, "!amountOut");
    }
}

contract MetaExchangeTest is Test {
    MockERC20 internal asset;
    MockERC20 internal bridgeA;
    MockERC20 internal bridgeB;
    MockERC20 internal bridgeC;
    MockERC20 internal finalToken;
    MockVault internal vault;
    MockSyrupVault internal syrupVault;
    MockSyrupRouter internal syrupRouter;
    MockWETH internal weth;
    MockERC20Decimals internal usdc;
    MockERC20Decimals internal usds;
    MockSUSDSVault internal susdsVault;
    MockLitePSM internal litePsm;

    MockMetaExchange internal exchange;
    MockStrategyForExchange internal strategy;
    MockStrategyForExchange internal secondStrategy;

    address internal constant NATIVE_ETH_ADDRESS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address internal governance = makeAddr("governance");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        asset = new MockERC20("Asset", "AST");
        bridgeA = new MockERC20("Bridge A", "BGA");
        bridgeB = new MockERC20("Bridge B", "BGB");
        bridgeC = new MockERC20("Bridge C", "BGC");
        finalToken = new MockERC20("Final", "FIN");
        vault = new MockVault(asset);
        syrupVault = new MockSyrupVault(asset);
        syrupRouter = new MockSyrupRouter(address(asset), address(syrupVault));
        weth = new MockWETH();
        usdc = new MockERC20Decimals("Mock USDC", "USDC", 6);
        usds = new MockERC20Decimals("Mock USDS", "USDS", 18);
        susdsVault = new MockSUSDSVault(usds);
        litePsm = new MockLitePSM(usdc, usds, 1e12);

        exchange = new MockMetaExchange(
            address(weth),
            address(usdc),
            address(usds),
            address(litePsm),
            1e12
        );
        strategy = new MockStrategyForExchange(address(this), governance);
        secondStrategy = new MockStrategyForExchange(address(this), governance);

        strategy.setExchange(address(exchange));
        secondStrategy.setExchange(address(exchange));

        strategy.approveToken(
            address(asset),
            address(exchange),
            type(uint256).max
        );
        strategy.approveToken(
            address(vault),
            address(exchange),
            type(uint256).max
        );
        strategy.approveToken(
            address(weth),
            address(exchange),
            type(uint256).max
        );
        strategy.approveToken(
            address(usdc),
            address(exchange),
            type(uint256).max
        );
        strategy.approveToken(
            address(usds),
            address(exchange),
            type(uint256).max
        );
        secondStrategy.approveToken(
            address(asset),
            address(exchange),
            type(uint256).max
        );
        secondStrategy.approveToken(
            address(vault),
            address(exchange),
            type(uint256).max
        );
        secondStrategy.approveToken(
            address(weth),
            address(exchange),
            type(uint256).max
        );
        secondStrategy.approveToken(
            address(usdc),
            address(exchange),
            type(uint256).max
        );
        secondStrategy.approveToken(
            address(usds),
            address(exchange),
            type(uint256).max
        );
    }

    function test_setRoute_requiresManagementOrOperator() public {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](2);
        route[0] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.UNISWAP_UNIVERSAL,
            tokenTo: address(asset)
        });
        route[1] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.PT,
            tokenTo: address(finalToken)
        });

        vm.prank(stranger);
        vm.expectRevert("!operator");
        exchange.setRoute(address(bridgeA), address(finalToken), route);

        exchange.setOperator(operator, true);

        vm.prank(operator);
        exchange.setRoute(address(bridgeA), address(finalToken), route);

        MetaExchange.RouteStep[] memory stored = exchange.getRoute(
            address(bridgeA),
            address(finalToken)
        );
        assertEq(stored.length, 2, "!length");
        assertEq(
            uint256(stored[0].venue),
            uint256(MetaExchange.Venue.UNISWAP_UNIVERSAL),
            "!venue0"
        );
        assertEq(stored[0].tokenTo, address(asset), "!token0");
        assertEq(
            uint256(stored[1].venue),
            uint256(MetaExchange.Venue.PT),
            "!venue1"
        );
        assertEq(stored[1].tokenTo, address(finalToken), "!token1");

        MetaExchange.RouteStep[]
            memory clearRoute = new MetaExchange.RouteStep[](0);
        vm.prank(operator);
        exchange.setRoute(address(bridgeA), address(finalToken), clearRoute);

        stored = exchange.getRoute(address(bridgeA), address(finalToken));
        assertEq(stored.length, 0, "!cleared");
    }

    function test_exchange_revertsWithoutRoute() public {
        asset.mint(address(strategy), 10e18);

        vm.expectRevert("!route");
        strategy.swap(address(asset), address(finalToken), 10e18, 0);
    }

    function test_exchange_sameToken_returnsInputWithoutRoute() public {
        asset.mint(address(strategy), 25e18);

        uint256 amountOut = strategy.swap(
            address(asset),
            address(asset),
            25e18,
            0
        );

        assertEq(amountOut, 25e18, "!amountOut");
        assertEq(asset.balanceOf(address(strategy)), 25e18, "!balance");
    }

    function test_exchange_erc4626DepositAndRedeem() public {
        MetaExchange.RouteStep[]
            memory depositRoute = new MetaExchange.RouteStep[](1);
        depositRoute[0] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.ERC4626_DEPOSIT,
            tokenTo: address(vault)
        });
        exchange.setRoute(address(asset), address(vault), depositRoute);

        MetaExchange.RouteStep[]
            memory redeemRoute = new MetaExchange.RouteStep[](1);
        redeemRoute[0] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.ERC4626_REDEEM,
            tokenTo: address(asset)
        });
        exchange.setRoute(address(vault), address(asset), redeemRoute);

        asset.mint(address(strategy), 100e18);

        uint256 sharesOut = strategy.swap(
            address(asset),
            address(vault),
            100e18,
            0
        );
        assertEq(sharesOut, 100e18, "!sharesOut");
        assertEq(vault.balanceOf(address(strategy)), 100e18, "!shares");

        uint256 assetOut = strategy.swap(
            address(vault),
            address(asset),
            sharesOut,
            0
        );
        assertEq(assetOut, 100e18, "!assetOut");
        assertEq(asset.balanceOf(address(strategy)), 100e18, "!asset");
        assertEq(vault.balanceOf(address(strategy)), 0, "!vault");
    }

    function test_exchange_dispatchesAcrossSwapVenues() public {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](4);
        route[0] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.UNISWAP_UNIVERSAL,
            tokenTo: address(bridgeA)
        });
        route[1] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.CURVE,
            tokenTo: address(bridgeB)
        });
        route[2] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.FLUID,
            tokenTo: address(bridgeC)
        });
        route[3] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.PT,
            tokenTo: address(finalToken)
        });
        exchange.setRoute(address(asset), address(finalToken), route);

        asset.mint(address(strategy), 50e18);
        uint256 amountOut = strategy.swap(
            address(asset),
            address(finalToken),
            50e18,
            0
        );

        assertEq(amountOut, 50e18, "!amountOut");
        assertEq(finalToken.balanceOf(address(strategy)), 50e18, "!final");
        assertEq(
            exchange.callCounts(uint256(MetaExchange.Venue.UNISWAP_UNIVERSAL)),
            1,
            "!uniCalls"
        );
        assertEq(
            exchange.callCounts(uint256(MetaExchange.Venue.CURVE)),
            1,
            "!curveCalls"
        );
        assertEq(
            exchange.callCounts(uint256(MetaExchange.Venue.FLUID)),
            1,
            "!fluidCalls"
        );
        assertEq(
            exchange.callCounts(uint256(MetaExchange.Venue.PT)),
            1,
            "!ptCalls"
        );
    }

    function test_exchange_allowsMultipleStrategies() public {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](1);
        route[0] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.UNISWAP_UNIVERSAL,
            tokenTo: address(finalToken)
        });
        exchange.setRoute(address(asset), address(finalToken), route);

        asset.mint(address(strategy), 10e18);
        asset.mint(address(secondStrategy), 20e18);

        uint256 firstOut = strategy.swap(
            address(asset),
            address(finalToken),
            10e18,
            0
        );
        uint256 secondOut = secondStrategy.swap(
            address(asset),
            address(finalToken),
            20e18,
            0
        );

        assertEq(firstOut, 10e18, "!firstOut");
        assertEq(secondOut, 20e18, "!secondOut");
        assertEq(finalToken.balanceOf(address(strategy)), 10e18, "!first");
        assertEq(
            finalToken.balanceOf(address(secondStrategy)),
            20e18,
            "!second"
        );
    }

    function test_exchange_litePsmSwap_bothDirections() public {
        MetaExchange.RouteStep[]
            memory sellRoute = new MetaExchange.RouteStep[](1);
        sellRoute[0] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.LITE_PSM,
            tokenTo: address(usds)
        });
        exchange.setRoute(address(usdc), address(usds), sellRoute);

        MetaExchange.RouteStep[] memory buyRoute = new MetaExchange.RouteStep[](
            1
        );
        buyRoute[0] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.LITE_PSM,
            tokenTo: address(usdc)
        });
        exchange.setRoute(address(usds), address(usdc), buyRoute);

        usdc.mint(address(strategy), 15e6);

        uint256 usdsOut = strategy.swap(address(usdc), address(usds), 15e6, 0);
        assertEq(usdsOut, 15e18, "!usdsOut");
        assertEq(usds.balanceOf(address(strategy)), 15e18, "!usds");

        uint256 usdcOut = strategy.swap(address(usds), address(usdc), 15e18, 0);
        assertEq(usdcOut, 15e6, "!usdcOut");
        assertEq(usdc.balanceOf(address(strategy)), 15e6, "!usdc");
    }

    function test_exchange_wrapsAndUnwrapsNative() public {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](3);
        route[0] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.WRAPPED_NATIVE,
            tokenTo: NATIVE_ETH_ADDRESS
        });
        route[1] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.WRAPPED_NATIVE,
            tokenTo: address(weth)
        });
        route[2] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.UNISWAP_UNIVERSAL,
            tokenTo: address(finalToken)
        });
        exchange.setRoute(address(weth), address(finalToken), route);

        vm.deal(address(weth), 3e18);
        weth.mint(address(strategy), 3e18);

        uint256 amountOut = strategy.swap(
            address(weth),
            address(finalToken),
            3e18,
            0
        );

        assertEq(amountOut, 3e18, "!amountOut");
        assertEq(finalToken.balanceOf(address(strategy)), 3e18, "!final");
        assertEq(address(exchange).balance, 0, "!ethDust");
        assertEq(weth.balanceOf(address(exchange)), 0, "!wethDust");
        assertEq(
            exchange.callCounts(uint256(MetaExchange.Venue.UNISWAP_UNIVERSAL)),
            1,
            "!uniCalls"
        );
    }

    function test_exchange_syrupDeposit_usesRouterAndDepositData() public {
        exchange.setSyrupDepositConfig(
            address(syrupVault),
            address(syrupRouter),
            bytes32("Yearn")
        );

        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](1);
        route[0] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.SYRUP_DEPOSIT,
            tokenTo: address(syrupVault)
        });
        exchange.setRoute(address(asset), address(syrupVault), route);

        asset.mint(address(strategy), 75e18);

        uint256 sharesOut = strategy.swap(
            address(asset),
            address(syrupVault),
            75e18,
            0
        );

        assertEq(sharesOut, 75e18, "!sharesOut");
        assertEq(syrupVault.balanceOf(address(strategy)), 75e18, "!shares");
        assertEq(syrupRouter.depositCalls(), 1, "!depositCalls");
        assertEq(syrupRouter.lastAmount(), 75e18, "!amount");
        assertEq(syrupRouter.lastDepositData(), bytes32("Yearn"), "!data");
    }

    function test_exchange_susdsDeposit_usesReferral() public {
        exchange.setSUSDSReferral(42);

        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](1);
        route[0] = MetaExchange.RouteStep({
            venue: MetaExchange.Venue.SUSDS_DEPOSIT,
            tokenTo: address(susdsVault)
        });
        exchange.setRoute(address(usds), address(susdsVault), route);

        usds.mint(address(strategy), 25e18);

        uint256 sharesOut = strategy.swap(
            address(usds),
            address(susdsVault),
            25e18,
            0
        );

        assertEq(sharesOut, 25e18, "!sharesOut");
        assertEq(susdsVault.balanceOf(address(strategy)), 25e18, "!shares");
        assertEq(susdsVault.lastAssets(), 25e18, "!assets");
        assertEq(susdsVault.lastReceiver(), address(exchange), "!receiver");
        assertEq(susdsVault.lastReferral(), 42, "!referral");
    }
}
