// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {OriginMorphoLooper} from "../../../morpho/OriginMorphoLooper.sol";
import {IStrategyInterface} from "../../../interfaces/IStrategyInterface.sol";
import {IMorpho, Id, MarketParams} from "../../../interfaces/morpho/IMorpho.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";
import {CurveExchange} from "../../../periphery/CurveExchange.sol";
import {ERC4626Exchange} from "../../../periphery/ERC4626Exchange.sol";
import {OriginMintExchange} from "../../../periphery/OriginMintExchange.sol";

/// @notice Setup for wOUSD/USDC Morpho looper tests.
contract SetupWOUSDMorpho is Setup {
    MetaExchange public exchange;
    CurveExchange public curveExchange;
    ERC4626Exchange public erc4626Exchange;
    OriginMintExchange public originExchange;

    Id public constant WOUSD_USDC_MARKET_ID =
        Id.wrap(
            0xad656d430bb3d8c1469bf45c8ad4ebae1b04be04757c69fa424eec78d7b3f4dc
        );

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant OUSD = 0x2A8e1E676Ec238d8A992307B495b45B3fEAa5e86;
    address public constant WOUSD = 0xD2af830E8CBdFed6CC11Bab697bB25496ed6FA62;
    address public constant OUSD_VAULT =
        0xE75D77B1865Ae93c7eaa3040B038D7aA7BC02F70;
    address public constant CURVE_OUSD_USDC_POOL =
        0x6d18E1a7faeB1F0467A77C0d293872ab685426dc;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 public constant WOUSD_MORPHO_LIQUIDITY_SEED = 5_000_000e6;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        user = makeAddr("wousd-usdc-user");

        tokenAddrs["USDC"] = USDC;
        tokenAddrs["OUSD"] = OUSD;
        tokenAddrs["WOUSD"] = WOUSD;

        asset = ERC20(USDC);
        decimals = asset.decimals();

        // Direct mint on the way in is fat, but the live OUSD->USDC Curve exit
        // still taps out if lever tests get too greedy.
        maxFuzzAmount = 20_000e6;
        minFuzzAmount = 1_000e6;

        strategy = IStrategyInterface(setUpStrategy());
        _seedWOUSDMorphoLiquidity(WOUSD_MORPHO_LIQUIDITY_SEED);

        factory = strategy.FACTORY();

        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(address(exchange), "exchange");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(OUSD, "OUSD");
        vm.label(WOUSD, "WOUSD");
        vm.label(OUSD_VAULT, "OUSD_VAULT");
        vm.label(CURVE_OUSD_USDC_POOL, "CURVE_OUSD_USDC_POOL");
    }

    function setUpStrategy() public virtual override returns (address) {
        exchange = new MetaExchange(WETH);
        curveExchange = new CurveExchange();
        erc4626Exchange = new ERC4626Exchange();
        originExchange = new OriginMintExchange();

        OriginMorphoLooper looper = new OriginMorphoLooper(
            address(asset),
            "wOUSD/USDC Morpho Looper",
            WOUSD,
            MORPHO,
            WOUSD_USDC_MARKET_ID,
            address(exchange),
            management
        );

        IStrategyInterface _strategy = IStrategyInterface(address(looper));
        exchange.transferGovernance(management);
        curveExchange.transferGovernance(management);
        erc4626Exchange.transferGovernance(management);
        originExchange.transferGovernance(management);
        _strategy.setPendingManagement(management);

        vm.startPrank(management);
        _strategy.acceptManagement();

        _setCurveRoute(OUSD, address(asset), 0, 1);
        exchange.setAllowedExchange(address(curveExchange), true);
        exchange.setAllowedExchange(address(erc4626Exchange), true);
        exchange.setAllowedExchange(address(originExchange), true);
        _setRoutes();

        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setEmergencyAdmin(emergencyAdmin);
        _strategy.setAllowed(user, true);
        _strategy.setMaxGasPriceToTend(type(uint256).max);
        vm.stopPrank();

        return address(_strategy);
    }

    function accrueYield(uint256 _amount) public virtual override {
        skip(1 days);
        airdrop(asset, address(strategy), (_amount * 300) / 10_000);
    }

    function _seedWOUSDMorphoLiquidity(uint256 _amount) internal {
        MarketParams memory params = IMorpho(MORPHO).idToMarketParams(
            WOUSD_USDC_MARKET_ID
        );
        deal(address(asset), address(this), _amount);
        asset.approve(MORPHO, _amount);
        IMorpho(MORPHO).supply(params, _amount, 0, address(this), "");
    }

    function _setRoutes() internal {
        MetaExchange.RouteStep[] memory forward = new MetaExchange.RouteStep[](
            2
        );
        forward[0] = MetaExchange.RouteStep({
            exchange: address(originExchange),
            tokenTo: OUSD
        });
        forward[1] = MetaExchange.RouteStep({
            exchange: address(erc4626Exchange),
            tokenTo: WOUSD
        });
        exchange.setRoute(address(asset), WOUSD, forward);

        MetaExchange.RouteStep[] memory reverse = new MetaExchange.RouteStep[](
            2
        );
        reverse[0] = MetaExchange.RouteStep({
            exchange: address(erc4626Exchange),
            tokenTo: OUSD
        });
        reverse[1] = MetaExchange.RouteStep({
            exchange: address(curveExchange),
            tokenTo: address(asset)
        });
        exchange.setRoute(WOUSD, address(asset), reverse);
    }

    function _setCurveRoute(
        address _from,
        address _to,
        uint256 _i,
        uint256 _j
    ) internal {
        address[11] memory route;
        route[0] = _from;
        route[1] = CURVE_OUSD_USDC_POOL;
        route[2] = _to;

        uint256[5][5] memory swapParams;
        swapParams[0] = [_i, _j, 1, 1, 2];

        address[5] memory pools;

        curveExchange.setCurveRoute(_from, _to, route, swapParams, pools);
    }
}
