// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

import {BaseExchange} from "./BaseExchange.sol";
import {ILitePSMWrapper} from "../interfaces/sky/ILitePSMWrapper.sol";
import {ISUSDS} from "../interfaces/sky/ISUSDS.sol";

/**
 * @title SUSDSUSDTExchange
 * @notice Strategy-bound exchange for USDT <-> sUSDS conversion path.
 *         Path:
 *         - USDT -> USDC (UniswapV3) -> USDS (LitePSM) -> sUSDS
 *         - sUSDS -> USDS -> USDC (LitePSM) -> USDT (UniswapV3)
 */
contract SUSDSUSDTExchange is UniswapV3Swapper, BaseExchange {
    using SafeERC20 for ERC20;

    /// @notice Borrow asset token (USDT) for this fixed exchange path.
    address public constant ASSET = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    /// @notice Collateral token (sUSDS) for this fixed exchange path.
    address public constant COLLATERAL =
        0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant LITE_PSM_WRAPPER =
        0xA188EEC8F81263234dA3622A406892F3D630f98c;

    uint256 internal constant USDS_TO_USDC_SCALE = 1e12;

    /// @notice Referral code forwarded to sUSDS deposit.
    uint16 public susdsReferral = 1007;

    constructor() {
        base = USDC;
        _setUniFees(ASSET, USDC, 100);

        address usds = address(IERC4626(COLLATERAL).asset());
        ERC20(USDC).forceApprove(LITE_PSM_WRAPPER, type(uint256).max);
        ERC20(usds).forceApprove(LITE_PSM_WRAPPER, type(uint256).max);
        ERC20(usds).forceApprove(COLLATERAL, type(uint256).max);
    }

    function setUniFees(
        address _token0,
        address _token1,
        uint24 _fee
    ) external onlyManagement {
        _setUniFees(_token0, _token1, _fee);
    }

    function setBase(address _base) external onlyManagement {
        base = _base;
    }

    function setRouter(address _router) external onlyManagement {
        require(_router != address(0), "!router");
        router = _router;
    }

    function setSUSDSReferral(uint16 _susdsReferral) external onlyManagement {
        susdsReferral = _susdsReferral;
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal virtual override returns (uint256 amountOut) {
        if (from == ASSET && to == COLLATERAL) {
            return _swapAssetToCollateral(amountIn, amountOutMin);
        } else if (from == COLLATERAL && to == ASSET) {
            return _swapCollateralToAsset(amountIn, amountOutMin);
        } else {
            revert("!path");
        }
    }

    function _swapAssetToCollateral(
        uint256 amountIn,
        uint256
    ) internal returns (uint256 amountOut) {
        uint256 usdcAmount = UniswapV3Swapper._swapFrom(
            ASSET,
            USDC,
            amountIn,
            0
        );
        uint256 usdsAmount = ILitePSMWrapper(LITE_PSM_WRAPPER).sellGem(
            address(this),
            usdcAmount
        );
        amountOut = ISUSDS(COLLATERAL).deposit(
            usdsAmount,
            address(this),
            susdsReferral
        );
    }

    function _swapCollateralToAsset(
        uint256 amountIn,
        uint256 amountOutMin
    ) internal returns (uint256 amountOut) {
        uint256 usdsAmount = IERC4626(COLLATERAL).redeem(
            amountIn,
            address(this),
            address(this)
        );
        uint256 usdcAmount = usdsAmount / USDS_TO_USDC_SCALE;
        require(usdcAmount > 0, "!amountOut");

        ILitePSMWrapper(LITE_PSM_WRAPPER).buyGem(address(this), usdcAmount);
        amountOut = UniswapV3Swapper._swapFrom(
            USDC,
            ASSET,
            usdcAmount,
            amountOutMin
        );
    }
}
