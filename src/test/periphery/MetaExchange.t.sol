// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {IExchange} from "../../interfaces/IExchange.sol";
import {ISyrupRouter} from "../../interfaces/syrup/ISyrupRouter.sol";
import {MetaExchange} from "../../periphery/MetaExchange.sol";
import {BaseExchange} from "../../periphery/BaseExchange.sol";
import {ERC4626Exchange} from "../../periphery/ERC4626Exchange.sol";
import {LitePsmExchange} from "../../periphery/LitePsmExchange.sol";
import {OriginMintExchange} from "../../periphery/OriginMintExchange.sol";
import {SUSDSExchange} from "../../periphery/SUSDSExchange.sol";
import {SyrupDepositExchange} from "../../periphery/SyrupDepositExchange.sol";

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
    uint256 public authorizeAndDepositCalls;
    uint256 public lastAmount;
    bytes32 public lastDepositData;
    uint256 public lastBitmap;
    uint256 public lastDeadline;
    uint8 public lastV;
    bytes32 public lastR;
    bytes32 public lastS;

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
        uint256 bitmap,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint256 amount,
        bytes32 depositData
    ) external returns (uint256 amountOut) {
        authorizeAndDepositCalls += 1;
        lastBitmap = bitmap;
        lastDeadline = deadline;
        lastV = v;
        lastR = r;
        lastS = s;
        lastAmount = amount;
        lastDepositData = depositData;

        asset.transferFrom(msg.sender, address(this), amount);
        vault.mintShares(msg.sender, amount);
        return amount;
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

contract MockOriginToken is MockERC20 {
    address internal originVault;

    constructor(
        string memory name_,
        string memory symbol_
    ) MockERC20(name_, symbol_) {}

    function vaultAddress() external view returns (address) {
        return originVault;
    }

    function setVaultAddress(address vault_) external {
        originVault = vault_;
    }
}

contract MockOriginVault {
    ERC20 public immutable asset;
    MockOriginToken public immutable ousd;

    constructor(address asset_, address ousd_) {
        asset = ERC20(asset_);
        ousd = MockOriginToken(ousd_);
    }

    function mint(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        ousd.mint(msg.sender, amount);
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

contract MockVenueExchange is BaseExchange {
    uint256 public calls;
    mapping(address => mapping(address => address)) public uniBases;
    mapping(address => mapping(address => address)) public fluidBases;

    constructor(address _governance) BaseExchange(_governance) {}

    function name() external pure override returns (string memory) {
        return "MockVenueExchange";
    }

    function setUniBaseForPair(
        address token0,
        address token1,
        address uniBase
    ) external onlyOperator {
        uniBases[token0][token1] = uniBase;
        uniBases[token1][token0] = uniBase;
    }

    function setFluidBaseForPair(
        address token0,
        address token1,
        address fluidBase
    ) external onlyOperator {
        fluidBases[token0][token1] = fluidBase;
        fluidBases[token1][token0] = fluidBase;
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256
    ) internal override returns (uint256 amountOut) {
        calls += 1;
        require(ERC20(from).transfer(address(0xdead), amountIn), "!fromSpend");
        amountOut = amountIn;
        IMintableToken(to).mint(address(this), amountOut);
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
    MockOriginToken internal originToken;
    MockOriginVault internal originVault;
    MockVault internal wrappedOriginVault;

    MetaExchange internal exchange;
    MockVenueExchange internal uniExchange;
    MockVenueExchange internal curveExchange;
    MockVenueExchange internal fluidExchange;
    MockVenueExchange internal pendleExchange;
    ERC4626Exchange internal erc4626Exchange;
    LitePsmExchange internal litePsmExchange;
    SyrupDepositExchange internal syrupExchange;
    SUSDSExchange internal susdsExchange;
    OriginMintExchange internal originExchange;
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
        originToken = new MockOriginToken("Mock OUSD", "mOUSD");
        originVault = new MockOriginVault(address(asset), address(originToken));
        originToken.setVaultAddress(address(originVault));
        wrappedOriginVault = new MockVault(originToken);

        exchange = new MetaExchange(address(this));
        uniExchange = new MockVenueExchange(address(this));
        curveExchange = new MockVenueExchange(address(this));
        fluidExchange = new MockVenueExchange(address(this));
        pendleExchange = new MockVenueExchange(address(this));
        erc4626Exchange = new ERC4626Exchange(address(this));
        litePsmExchange = new LitePsmExchange(
            address(usdc),
            address(usds),
            address(litePsm),
            1e12,
            address(this)
        );
        syrupExchange = new SyrupDepositExchange(address(this));
        susdsExchange = new SUSDSExchange(address(this));
        originExchange = new OriginMintExchange(address(this));
        _allowTestExchanges();
        strategy = new MockStrategyForExchange(address(this), governance);
        secondStrategy = new MockStrategyForExchange(address(this), governance);

        strategy.setExchange(address(exchange));
        secondStrategy.setExchange(address(exchange));
        syrupExchange.setAllowed(address(strategy), true);

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
            address(wrappedOriginVault),
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
            address(wrappedOriginVault),
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

    function _allowTestExchanges() internal {
        exchange.setAllowedExchange(address(uniExchange), true);
        exchange.setAllowedExchange(address(curveExchange), true);
        exchange.setAllowedExchange(address(fluidExchange), true);
        exchange.setAllowedExchange(address(pendleExchange), true);
        exchange.setAllowedExchange(address(erc4626Exchange), true);
        exchange.setAllowedExchange(address(litePsmExchange), true);
        exchange.setAllowedExchange(address(syrupExchange), true);
        exchange.setAllowedExchange(address(susdsExchange), true);
        exchange.setAllowedExchange(address(originExchange), true);
        exchange.setContextAwareExchange(address(syrupExchange), true);
        syrupExchange.setAllowedForwarder(address(exchange), true);
    }

    function test_setAllowedExchange_tracksEnumerableSet() public {
        assertEq(exchange.allowedExchangesLength(), 9, "!initial length");
        assertEq(
            exchange.allowedExchangeAt(0),
            address(uniExchange),
            "!first exchange"
        );

        address[] memory allowed = exchange.getAllowedExchanges();
        assertEq(allowed.length, 9, "!allowed length");
        assertTrue(_contains(allowed, address(uniExchange)), "!uni");
        assertTrue(_contains(allowed, address(originExchange)), "!origin");

        exchange.setAllowedExchange(address(pendleExchange), false);
        allowed = exchange.getAllowedExchanges();
        assertEq(exchange.allowedExchangesLength(), 8, "!removed length");
        assertFalse(
            exchange.allowedExchanges(address(pendleExchange)),
            "!pendle mapping"
        );
        assertFalse(_contains(allowed, address(pendleExchange)), "!pendle set");

        exchange.setAllowedExchange(address(pendleExchange), false);
        assertEq(exchange.allowedExchangesLength(), 8, "!double remove");

        exchange.setAllowedExchange(address(pendleExchange), true);
        allowed = exchange.getAllowedExchanges();
        assertEq(exchange.allowedExchangesLength(), 9, "!readded length");
        assertTrue(
            exchange.allowedExchanges(address(pendleExchange)),
            "!pendle mapping readd"
        );
        assertTrue(
            _contains(allowed, address(pendleExchange)),
            "!pendle set readd"
        );

        exchange.setAllowedExchange(address(pendleExchange), true);
        assertEq(exchange.allowedExchangesLength(), 9, "!double add");
    }

    function test_exchangeNames_areExposed() public view {
        assertEq(exchange.name(), "MetaExchange", "!meta name");
        assertEq(uniExchange.name(), "MockVenueExchange", "!mock name");
        assertEq(erc4626Exchange.name(), "ERC4626Exchange", "!4626 name");
        assertEq(litePsmExchange.name(), "LitePsmExchange", "!psm name");
        assertEq(syrupExchange.name(), "SyrupDepositExchange", "!syrup name");
        assertEq(susdsExchange.name(), "SUSDSExchange", "!susds name");
        assertEq(originExchange.name(), "OriginMintExchange", "!origin name");
    }

    function test_syrupDeposit_sweep_onlyGovernance() public {
        asset.mint(address(syrupExchange), 123e18);

        vm.prank(stranger);
        vm.expectRevert("!governance");
        syrupExchange.sweep(address(asset), type(uint256).max);

        vm.expectRevert("!token");
        syrupExchange.sweep(address(0), type(uint256).max);

        syrupExchange.sweep(address(asset), type(uint256).max);

        assertEq(asset.balanceOf(address(this)), 123e18, "!swept");
        assertEq(asset.balanceOf(address(syrupExchange)), 0, "!remaining");
    }

    function test_setRoute_requiresGovernanceOrOperator() public {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](2);
        route[0] = MetaExchange.RouteStep({
            exchange: address(uniExchange),
            tokenFrom: address(bridgeA),
            tokenTo: address(asset)
        });
        route[1] = MetaExchange.RouteStep({
            exchange: address(pendleExchange),
            tokenFrom: address(asset),
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
        assertEq(stored[0].exchange, address(uniExchange), "!exchange0");
        assertEq(stored[0].tokenTo, address(asset), "!token0");
        assertEq(stored[1].exchange, address(pendleExchange), "!exchange1");
        assertEq(stored[1].tokenTo, address(finalToken), "!token1");

        MetaExchange.RouteStep[]
            memory clearRoute = new MetaExchange.RouteStep[](0);
        vm.prank(operator);
        exchange.setRoute(address(bridgeA), address(finalToken), clearRoute);

        stored = exchange.getRoute(address(bridgeA), address(finalToken));
        assertEq(stored.length, 0, "!cleared");
    }

    function test_setRoute_requiresAllowedExchange() public {
        MockVenueExchange unallowedExchange = new MockVenueExchange(
            address(this)
        );

        vm.prank(stranger);
        vm.expectRevert("!governance");
        exchange.setAllowedExchange(address(unallowedExchange), true);

        vm.expectRevert("!exchange");
        exchange.setAllowedExchange(address(0), true);

        vm.prank(stranger);
        vm.expectRevert("!governance");
        exchange.setContextAwareExchange(address(unallowedExchange), true);

        vm.expectRevert("!exchange");
        exchange.setContextAwareExchange(address(0), true);

        vm.expectRevert("!allowed");
        exchange.setContextAwareExchange(address(unallowedExchange), true);

        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](1);
        route[0] = MetaExchange.RouteStep({
            exchange: address(unallowedExchange),
            tokenFrom: address(asset),
            tokenTo: address(finalToken)
        });

        vm.expectRevert("!allowed");
        exchange.setRoute(address(asset), address(finalToken), route);

        exchange.setAllowedExchange(address(unallowedExchange), true);
        exchange.setContextAwareExchange(address(unallowedExchange), true);
        assertTrue(
            exchange.contextAwareExchanges(address(unallowedExchange)),
            "!context aware"
        );
        exchange.setRoute(address(asset), address(finalToken), route);

        MetaExchange.RouteStep[] memory stored = exchange.getRoute(
            address(asset),
            address(finalToken)
        );
        assertEq(stored.length, 1, "!length");
        assertEq(stored[0].exchange, address(unallowedExchange), "!exchange");

        exchange.setAllowedExchange(address(unallowedExchange), false);
        assertFalse(
            exchange.contextAwareExchanges(address(unallowedExchange)),
            "!context aware cleared"
        );
        asset.mint(address(strategy), 1e18);

        vm.expectRevert("!allowed");
        strategy.swap(address(asset), address(finalToken), 1e18, 0);
    }

    function _contains(
        address[] memory values,
        address target
    ) internal pure returns (bool) {
        for (uint256 i; i < values.length; ) {
            if (values[i] == target) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function test_setUniBaseForPair_requiresGovernanceOrOperator() public {
        vm.prank(stranger);
        vm.expectRevert("!operator");
        uniExchange.setUniBaseForPair(
            address(asset),
            address(finalToken),
            address(bridgeA)
        );

        uniExchange.setOperator(operator, true);

        vm.prank(operator);
        uniExchange.setUniBaseForPair(
            address(asset),
            address(finalToken),
            address(bridgeA)
        );

        assertEq(
            uniExchange.uniBases(address(asset), address(finalToken)),
            address(bridgeA),
            "!uni base"
        );
        assertEq(
            uniExchange.uniBases(address(finalToken), address(asset)),
            address(bridgeA),
            "!uni base reverse"
        );

        vm.prank(operator);
        uniExchange.setUniBaseForPair(
            address(asset),
            address(finalToken),
            address(0)
        );
        assertEq(
            uniExchange.uniBases(address(asset), address(finalToken)),
            address(0),
            "!uni base cleared"
        );
    }

    function test_setFluidBaseForPair_requiresGovernanceOrOperator() public {
        vm.prank(stranger);
        vm.expectRevert("!operator");
        fluidExchange.setFluidBaseForPair(
            address(asset),
            address(finalToken),
            address(bridgeB)
        );

        fluidExchange.setOperator(operator, true);

        vm.prank(operator);
        fluidExchange.setFluidBaseForPair(
            address(asset),
            address(finalToken),
            address(bridgeB)
        );

        assertEq(
            fluidExchange.fluidBases(address(asset), address(finalToken)),
            address(bridgeB),
            "!fluid base"
        );
        assertEq(
            fluidExchange.fluidBases(address(finalToken), address(asset)),
            address(bridgeB),
            "!fluid base reverse"
        );

        vm.prank(operator);
        fluidExchange.setFluidBaseForPair(
            address(asset),
            address(finalToken),
            address(0)
        );
        assertEq(
            fluidExchange.fluidBases(address(asset), address(finalToken)),
            address(0),
            "!fluid base cleared"
        );
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
            exchange: address(erc4626Exchange),
            tokenFrom: address(asset),
            tokenTo: address(vault)
        });
        exchange.setRoute(address(asset), address(vault), depositRoute);

        MetaExchange.RouteStep[]
            memory redeemRoute = new MetaExchange.RouteStep[](1);
        redeemRoute[0] = MetaExchange.RouteStep({
            exchange: address(erc4626Exchange),
            tokenFrom: address(vault),
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

    function test_exchange_dispatchesAcrossLinkedVenues() public {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](4);
        route[0] = MetaExchange.RouteStep({
            exchange: address(uniExchange),
            tokenFrom: address(asset),
            tokenTo: address(bridgeA)
        });
        route[1] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenFrom: address(bridgeA),
            tokenTo: address(bridgeB)
        });
        route[2] = MetaExchange.RouteStep({
            exchange: address(fluidExchange),
            tokenFrom: address(bridgeB),
            tokenTo: address(bridgeC)
        });
        route[3] = MetaExchange.RouteStep({
            exchange: address(pendleExchange),
            tokenFrom: address(bridgeC),
            tokenTo: address(finalToken)
        });
        exchange.setRoute(address(asset), address(finalToken), route);

        assertEq(
            asset.allowance(address(exchange), address(uniExchange)),
            0,
            "!allowance0"
        );
        assertEq(
            bridgeA.allowance(address(exchange), address(curveExchange)),
            0,
            "!allowance1"
        );
        assertEq(
            bridgeB.allowance(address(exchange), address(fluidExchange)),
            0,
            "!allowance2"
        );
        assertEq(
            bridgeC.allowance(address(exchange), address(pendleExchange)),
            0,
            "!allowance3"
        );

        asset.mint(address(strategy), 50e18);
        uint256 amountOut = strategy.swap(
            address(asset),
            address(finalToken),
            50e18,
            0
        );

        assertEq(amountOut, 50e18, "!amountOut");
        assertEq(finalToken.balanceOf(address(strategy)), 50e18, "!final");
        uint256 expectedAllowance = 0;
        assertEq(
            asset.allowance(address(exchange), address(uniExchange)),
            expectedAllowance,
            "!postAllowance0"
        );
        assertEq(
            bridgeA.allowance(address(exchange), address(curveExchange)),
            expectedAllowance,
            "!postAllowance1"
        );
        assertEq(
            bridgeB.allowance(address(exchange), address(fluidExchange)),
            expectedAllowance,
            "!postAllowance2"
        );
        assertEq(
            bridgeC.allowance(address(exchange), address(pendleExchange)),
            expectedAllowance,
            "!postAllowance3"
        );
        assertEq(uniExchange.calls(), 1, "!uniCalls");
        assertEq(curveExchange.calls(), 1, "!curveCalls");
        assertEq(fluidExchange.calls(), 1, "!fluidCalls");
        assertEq(pendleExchange.calls(), 1, "!ptCalls");
    }

    function test_exchange_allowsMultipleStrategies() public {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](1);
        route[0] = MetaExchange.RouteStep({
            exchange: address(uniExchange),
            tokenFrom: address(asset),
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
            exchange: address(litePsmExchange),
            tokenFrom: address(usdc),
            tokenTo: address(usds)
        });
        exchange.setRoute(address(usdc), address(usds), sellRoute);

        MetaExchange.RouteStep[] memory buyRoute = new MetaExchange.RouteStep[](
            1
        );
        buyRoute[0] = MetaExchange.RouteStep({
            exchange: address(litePsmExchange),
            tokenFrom: address(usds),
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

    function test_exchange_routesWethThroughLinkedExchange() public {
        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](1);
        route[0] = MetaExchange.RouteStep({
            exchange: address(uniExchange),
            tokenFrom: address(weth),
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
        assertEq(uniExchange.calls(), 1, "!uniCalls");
    }

    function test_exchange_syrupDeposit_usesRouterAndDepositData() public {
        syrupExchange.setSyrupDepositConfig(
            address(syrupVault),
            address(syrupRouter),
            bytes32("0:Yearn")
        );

        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](1);
        route[0] = MetaExchange.RouteStep({
            exchange: address(syrupExchange),
            tokenFrom: address(asset),
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
        assertEq(syrupRouter.lastDepositData(), bytes32("0:Yearn"), "!data");
    }

    function test_syrupDeposit_authorizeAndDeposit_onlyGovernance() public {
        syrupExchange.setSyrupDepositConfig(
            address(syrupVault),
            address(syrupRouter),
            bytes32("0:Yearn")
        );

        asset.mint(stranger, 75e18);

        vm.startPrank(stranger);
        asset.approve(address(syrupExchange), 75e18);
        vm.expectRevert("!governance");
        syrupExchange.authorizeAndDeposit(
            address(syrupVault),
            75e18,
            0,
            SyrupDepositExchange.SyrupAuthorization({
                bitmap: 1,
                deadline: block.timestamp + 1 days,
                v: 28,
                r: bytes32(uint256(2)),
                s: bytes32(uint256(3))
            })
        );
        vm.stopPrank();
    }

    function test_syrupDeposit_authorizeAndDeposit_usesSignatureAndDepositData()
        public
    {
        bytes32 depositData = bytes32("0:Yearn");
        bytes32 r = bytes32(uint256(2));
        bytes32 s = bytes32(uint256(3));
        uint256 deadline = block.timestamp + 1 days;

        syrupExchange.setSyrupDepositConfig(
            address(syrupVault),
            address(syrupRouter),
            depositData
        );

        asset.mint(address(syrupExchange), 75e18);

        uint256 sharesOut = syrupExchange.authorizeAndDeposit(
            address(syrupVault),
            75e18,
            75e18,
            SyrupDepositExchange.SyrupAuthorization({
                bitmap: 1,
                deadline: deadline,
                v: 28,
                r: r,
                s: s
            })
        );

        assertEq(sharesOut, 75e18, "!sharesOut");
        assertEq(
            syrupVault.balanceOf(address(syrupExchange)),
            75e18,
            "!shares"
        );
        assertEq(syrupRouter.authorizeAndDepositCalls(), 1, "!authCalls");
        assertEq(syrupRouter.depositCalls(), 0, "!depositCalls");
        assertEq(syrupRouter.lastAmount(), 75e18, "!amount");
        assertEq(syrupRouter.lastDepositData(), depositData, "!data");
        assertEq(syrupRouter.lastBitmap(), 1, "!bitmap");
        assertEq(syrupRouter.lastDeadline(), deadline, "!deadline");
        assertEq(syrupRouter.lastV(), 28, "!v");
        assertEq(syrupRouter.lastR(), r, "!r");
        assertEq(syrupRouter.lastS(), s, "!s");

        syrupExchange.sweep(address(syrupVault), type(uint256).max);
        assertEq(syrupVault.balanceOf(address(this)), 75e18, "!swept");
        assertEq(syrupVault.balanceOf(address(syrupExchange)), 0, "!dust");
    }

    function test_exchange_syrupDeposit_rejectsUnallowedContextThroughMetaExchange()
        public
    {
        syrupExchange.setSyrupDepositConfig(
            address(syrupVault),
            address(syrupRouter),
            bytes32("0:Yearn")
        );

        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](1);
        route[0] = MetaExchange.RouteStep({
            exchange: address(syrupExchange),
            tokenFrom: address(asset),
            tokenTo: address(syrupVault)
        });
        exchange.setRoute(address(asset), address(syrupVault), route);

        asset.mint(address(secondStrategy), 75e18);

        vm.expectRevert("!allowed");
        secondStrategy.swap(address(asset), address(syrupVault), 75e18, 0);
    }

    function test_exchange_syrupDeposit_rejectsDirectContextExchange() public {
        syrupExchange.setSyrupDepositConfig(
            address(syrupVault),
            address(syrupRouter),
            bytes32("0:Yearn")
        );

        asset.mint(address(secondStrategy), 75e18);

        vm.startPrank(address(secondStrategy));
        asset.approve(address(syrupExchange), 75e18);
        vm.expectRevert("!forwarder");
        syrupExchange.exchangeWithContext(
            address(asset),
            address(syrupVault),
            75e18,
            0,
            address(secondStrategy)
        );
        vm.stopPrank();
    }

    function test_exchange_susdsDeposit_usesReferral() public {
        susdsExchange.setSUSDSReferral(42);

        MetaExchange.RouteStep[] memory route = new MetaExchange.RouteStep[](1);
        route[0] = MetaExchange.RouteStep({
            exchange: address(susdsExchange),
            tokenFrom: address(usds),
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
        assertEq(
            susdsVault.lastReceiver(),
            address(susdsExchange),
            "!receiver"
        );
        assertEq(susdsVault.lastReferral(), 42, "!referral");
    }

    function test_exchange_originMintAndWrapsWousd() public {
        MetaExchange.RouteStep[] memory forward = new MetaExchange.RouteStep[](
            2
        );
        forward[0] = MetaExchange.RouteStep({
            exchange: address(originExchange),
            tokenFrom: address(asset),
            tokenTo: address(originToken)
        });
        forward[1] = MetaExchange.RouteStep({
            exchange: address(erc4626Exchange),
            tokenFrom: address(originToken),
            tokenTo: address(wrappedOriginVault)
        });
        exchange.setRoute(address(asset), address(wrappedOriginVault), forward);

        MetaExchange.RouteStep[] memory reverse = new MetaExchange.RouteStep[](
            2
        );
        reverse[0] = MetaExchange.RouteStep({
            exchange: address(erc4626Exchange),
            tokenFrom: address(wrappedOriginVault),
            tokenTo: address(originToken)
        });
        reverse[1] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenFrom: address(originToken),
            tokenTo: address(asset)
        });
        exchange.setRoute(address(wrappedOriginVault), address(asset), reverse);

        asset.mint(address(strategy), 33e18);

        uint256 sharesOut = strategy.swap(
            address(asset),
            address(wrappedOriginVault),
            33e18,
            0
        );
        assertEq(sharesOut, 33e18, "!sharesOut");
        assertEq(
            wrappedOriginVault.balanceOf(address(strategy)),
            33e18,
            "!shares"
        );

        uint256 assetOut = strategy.swap(
            address(wrappedOriginVault),
            address(asset),
            sharesOut,
            0
        );
        assertEq(assetOut, 33e18, "!assetOut");
        assertEq(asset.balanceOf(address(strategy)), 33e18, "!asset");
        assertEq(curveExchange.calls(), 1, "!curveCalls");
    }
}
