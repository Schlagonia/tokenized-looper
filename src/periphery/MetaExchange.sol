// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {CurveSwapper} from "@periphery/swappers/CurveSwapper.sol";
import {PendleSwapper} from "@periphery/swappers/PendleSwapper.sol";
import {UniswapUniversalSwapper} from "@periphery/swappers/UniswapUniversalSwapper.sol";

import {ILitePSMWrapper} from "../interfaces/sky/ILitePSMWrapper.sol";
import {ISUSDS} from "../interfaces/sky/ISUSDS.sol";
import {ISyrupRouter} from "../interfaces/syrup/ISyrupRouter.sol";
import {BaseExchange} from "./BaseExchange.sol";
import {MetaFluidSwapper} from "./MetaFluidSwapper.sol";

interface IMetaExchangeWETH {
    function deposit() external payable;

    function withdraw(uint256) external;
}

/**
 * @title MetaExchange
 * @notice Generic route-driven exchange that composes existing swappers and
 *         ERC-4626 deposit/redeem steps into explicit token routes.
 */
contract MetaExchange is
    UniswapUniversalSwapper,
    CurveSwapper,
    MetaFluidSwapper,
    PendleSwapper,
    BaseExchange
{
    using SafeERC20 for ERC20;

    enum Venue {
        NONE,
        UNISWAP_UNIVERSAL,
        CURVE,
        FLUID,
        PT,
        ERC4626_DEPOSIT,
        ERC4626_REDEEM,
        LITE_PSM,
        WRAPPED_NATIVE,
        SYRUP_DEPOSIT,
        SUSDS_DEPOSIT
    }

    struct RouteStep {
        Venue venue;
        address tokenTo;
    }

    struct SyrupDepositConfig {
        address router;
        bytes32 depositData;
    }

    address internal constant LITE_PSM_GEM =
        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant LITE_PSM_USDS =
        0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant LITE_PSM_WRAPPER =
        0xA188EEC8F81263234dA3622A406892F3D630f98c;
    uint256 internal constant LITE_PSM_SCALE = 1e12;

    address internal constant NATIVE_ETH_ADDRESS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    mapping(address => bool) public operators;
    mapping(address => SyrupDepositConfig) public syrupDepositConfigs;
    mapping(address => mapping(address => RouteStep[])) internal _routes;
    uint16 public susdsReferral = 1007;

    event OperatorSet(address indexed operator, bool allowed);
    event RouteSet(address indexed from, address indexed to, uint256 length);
    event SyrupDepositConfigSet(
        address indexed vault,
        address indexed router,
        bytes32 depositData
    );

    constructor(
        address _weth
    ) UniswapUniversalSwapper(_weth) MetaFluidSwapper(_weth) {}

    modifier onlyRouteOperator() {
        require(operators[msg.sender] || msg.sender == governance, "!operator");
        _;
    }

    function getRoute(
        address from,
        address to
    ) external view returns (RouteStep[] memory) {
        return _routes[from][to];
    }

    function setOperator(
        address operator,
        bool allowed
    ) external onlyGovernance {
        require(operator != address(0), "!operator");
        operators[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    function setRoute(
        address from,
        address to,
        RouteStep[] calldata route
    ) external onlyRouteOperator {
        require(from != address(0) && to != address(0), "!token");
        require(
            from != NATIVE_ETH_ADDRESS && to != NATIVE_ETH_ADDRESS,
            "!native"
        );

        delete _routes[from][to];

        uint256 length = route.length;
        if (length == 0) {
            emit RouteSet(from, to, 0);
            return;
        }

        require(route[length - 1].tokenTo == to, "!route");

        for (uint256 i; i < length; ) {
            RouteStep calldata step = route[i];
            require(step.venue != Venue.NONE, "!venue");
            require(step.tokenTo != address(0), "!tokenTo");
            _routes[from][to].push(step);
            unchecked {
                ++i;
            }
        }

        emit RouteSet(from, to, length);
    }

    function setMinAmountToSell(uint256 minAmount) external onlyGovernance {
        _setMinAmountToSell(minAmount);
    }

    function setUniBase(address uniBase) external onlyRouteOperator {
        require(uniBase != address(0), "!base");
        base = uniBase;
    }

    function setUniswapRouter(address _router) external onlyGovernance {
        require(_router != address(0), "!router");
        router = _router;
    }

    function setPositionManager(
        address _positionManager
    ) external onlyGovernance {
        require(_positionManager != address(0), "!positionManager");
        positionManager = _positionManager;
    }

    function setUniFees(
        address token0,
        address token1,
        uint24 fee
    ) external onlyRouteOperator {
        _setUniFees(token0, token1, fee);
    }

    function setV4Pool(
        address token0,
        address token1,
        bytes32 poolId
    ) external onlyRouteOperator {
        _setV4Pool(token0, token1, poolId);
    }

    function setCurveRoute(
        address from,
        address to,
        address[11] memory route,
        uint256[5][5] memory swapParams,
        address[5] memory pools
    ) external onlyRouteOperator {
        _setCurveRoute(from, to, route, swapParams, pools);
    }

    function setFluidBase(address _fluidBase) external onlyRouteOperator {
        require(_fluidBase != address(0), "!base");
        fluidBase = _fluidBase;
    }

    function setFluidDex(
        address token0,
        address token1,
        address dex
    ) external onlyRouteOperator {
        _setFluidDex(token0, token1, dex);
    }

    function setPendleMarket(
        address pt,
        address market
    ) external onlyRouteOperator {
        require(pt != address(0) && market != address(0), "!market");
        _setMarket(pt, market);
    }

    function setSyrupDepositConfig(
        address vault,
        address router,
        bytes32 depositData
    ) external onlyRouteOperator {
        require(vault != address(0) && router != address(0), "!syrup");
        syrupDepositConfigs[vault] = SyrupDepositConfig({
            router: router,
            depositData: depositData
        });
        emit SyrupDepositConfigSet(vault, router, depositData);
    }

    function setSUSDSReferral(uint16 referral) external onlyGovernance {
        susdsReferral = referral;
    }

    function setGuessMaxMultiplier(
        uint256 multiplier
    ) external onlyRouteOperator {
        _setGuessMaxMultiplier(multiplier);
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256
    ) internal override(BaseExchange) returns (uint256 amountOut) {
        if (from == to) return amountIn;

        RouteStep[] storage route = _routes[from][to];
        uint256 length = route.length;
        require(length != 0, "!route");

        address currentToken = from;
        amountOut = amountIn;

        for (uint256 i; i < length; ) {
            RouteStep storage step = route[i];
            amountOut = _swapStep(
                step.venue,
                currentToken,
                step.tokenTo,
                amountOut
            );
            currentToken = step.tokenTo;
            unchecked {
                ++i;
            }
        }

        require(currentToken == to, "!route");
    }

    function _swapStep(
        Venue venue,
        address from,
        address to,
        uint256 amountIn
    ) internal virtual returns (uint256 amountOut) {
        if (amountIn == 0) return 0;

        if (venue == Venue.UNISWAP_UNIVERSAL) {
            return UniswapUniversalSwapper._swapFrom(from, to, amountIn, 0);
        }
        if (venue == Venue.CURVE) {
            return CurveSwapper._curveSwapFrom(from, to, amountIn, 0);
        }
        if (venue == Venue.FLUID) {
            return MetaFluidSwapper._fluidSwapFrom(from, to, amountIn, 0);
        }
        if (venue == Venue.PT) {
            return PendleSwapper._pendleSwapFrom(from, to, amountIn, 0);
        }
        if (venue == Venue.ERC4626_DEPOSIT) {
            return _erc4626Deposit(from, to, amountIn);
        }
        if (venue == Venue.ERC4626_REDEEM) {
            return _erc4626Redeem(from, to, amountIn);
        }
        if (venue == Venue.LITE_PSM) {
            return _litePsmSwap(from, to, amountIn);
        }
        if (venue == Venue.WRAPPED_NATIVE) {
            return _wrapNative(from, to, amountIn);
        }
        if (venue == Venue.SYRUP_DEPOSIT) {
            return _syrupDeposit(from, to, amountIn);
        }
        if (venue == Venue.SUSDS_DEPOSIT) {
            return _susdsDeposit(from, to, amountIn);
        }

        revert("!venue");
    }

    function _erc4626Deposit(
        address from,
        address vault,
        uint256 amountIn
    ) internal virtual returns (uint256 amountOut) {
        require(IERC4626(vault).asset() == from, "!vaultAsset");
        _checkAllowance(vault, from, amountIn);
        return IERC4626(vault).deposit(amountIn, address(this));
    }

    function _erc4626Redeem(
        address vault,
        address to,
        uint256 amountIn
    ) internal virtual returns (uint256 amountOut) {
        require(IERC4626(vault).asset() == to, "!vaultAsset");
        return IERC4626(vault).redeem(amountIn, address(this), address(this));
    }

    function _litePsmSwap(
        address from,
        address to,
        uint256 amountIn
    ) internal virtual returns (uint256 amountOut) {
        if (from == LITE_PSM_GEM && to == LITE_PSM_USDS) {
            _checkAllowance(LITE_PSM_WRAPPER, from, amountIn);
            return
                ILitePSMWrapper(LITE_PSM_WRAPPER).sellGem(
                    address(this),
                    amountIn
                );
        }

        require(from == LITE_PSM_USDS && to == LITE_PSM_GEM, "!psm");

        uint256 gemAmount = amountIn / LITE_PSM_SCALE;
        require(gemAmount != 0, "!amountOut");

        _checkAllowance(LITE_PSM_WRAPPER, from, amountIn);

        uint256 balanceBefore = ERC20(to).balanceOf(address(this));
        ILitePSMWrapper(LITE_PSM_WRAPPER).buyGem(address(this), gemAmount);
        amountOut = ERC20(to).balanceOf(address(this)) - balanceBefore;
        require(amountOut != 0, "!amountOut");
    }

    function _wrapNative(
        address from,
        address to,
        uint256 amountIn
    ) internal virtual returns (uint256 amountOut) {
        if (from == weth && to == NATIVE_ETH_ADDRESS) {
            IMetaExchangeWETH(weth).withdraw(amountIn);
            return amountIn;
        }

        if (from == NATIVE_ETH_ADDRESS && to == weth) {
            IMetaExchangeWETH(weth).deposit{value: amountIn}();
            return amountIn;
        }

        revert("!wrap");
    }

    function _syrupDeposit(
        address from,
        address vault,
        uint256 amountIn
    ) internal virtual returns (uint256 amountOut) {
        require(IERC4626(vault).asset() == from, "!vaultAsset");

        SyrupDepositConfig memory config = syrupDepositConfigs[vault];
        require(config.router != address(0), "!syrup");

        _checkAllowance(config.router, from, amountIn);
        return
            ISyrupRouter(config.router).deposit(amountIn, config.depositData);
    }

    function _susdsDeposit(
        address from,
        address vault,
        uint256 amountIn
    ) internal virtual returns (uint256 amountOut) {
        require(IERC4626(vault).asset() == from, "!vaultAsset");

        _checkAllowance(vault, from, amountIn);
        return ISUSDS(vault).deposit(amountIn, address(this), susdsReferral);
    }

    function _checkAllowance(
        address spender,
        address token,
        uint256 amount
    ) internal override(CurveSwapper, PendleSwapper) {
        if (ERC20(token).allowance(address(this), spender) < amount) {
            ERC20(token).forceApprove(spender, type(uint256).max);
        }
    }
}
