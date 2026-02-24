// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseMorphoLooper} from "./BaseMorphoLooper.sol";
import {Id} from "../interfaces/morpho/IMorpho.sol";
import {ILitePSMWrapper} from "../interfaces/sky/ILitePSMWrapper.sol";
import {ISUSDS} from "../interfaces/sky/ISUSDS.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

/**
 * @notice Morpho looper for sUSDS collateral and USDT debt.
 *         Conversion path:
 *         - Asset -> collateral: USDT -> USDC (UniswapV3) -> USDS (LitePSM) -> sUSDS (ERC4626)
 *         - Collateral -> asset: sUSDS -> USDS (ERC4626) -> USDC (LitePSM) -> USDT (UniswapV3)
 */
contract SUSDSUSDTMorphoLooper is BaseMorphoLooper, UniswapV3Swapper {
    using SafeERC20 for ERC20;

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant LITE_PSM_WRAPPER =
        0xA188EEC8F81263234dA3622A406892F3D630f98c;

    uint256 internal constant USDS_TO_USDC_SCALE = 1e12;
    uint16 public susdsReferral;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId,
        address _router
    ) BaseMorphoLooper(_asset, _name, _collateralToken, _morpho, _marketId) {
        base = USDC;
        router = _router;
        _setUniFees(_asset, USDC, 100);

        address usds = address(IERC4626(_collateralToken).asset());

        ERC20(USDC).forceApprove(LITE_PSM_WRAPPER, type(uint256).max);
        ERC20(usds).forceApprove(LITE_PSM_WRAPPER, type(uint256).max);
        ERC20(usds).forceApprove(_collateralToken, type(uint256).max);
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

    function setSUSDSReferral(uint16 _susdsReferral) external onlyManagement {
        susdsReferral = _susdsReferral;
    }

    /*//////////////////////////////////////////////////////////////
                            CONVERSIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert USDT to sUSDS through USDC and USDS.
    function _convertAssetToCollateral(
        uint256 amount,
        uint256 amountOutMin
    ) internal override returns (uint256) {
        if (amount == 0) return 0;

        uint256 usdcAmount = _swapFrom(address(asset), USDC, amount, 0);
        uint256 usdsAmount = ILitePSMWrapper(LITE_PSM_WRAPPER).sellGem(
            address(this),
            usdcAmount
        );
        uint256 susdsAmount = ISUSDS(collateralToken).deposit(
            usdsAmount,
            address(this),
            susdsReferral
        );

        require(susdsAmount >= amountOutMin, "slippage");
        return susdsAmount;
    }

    /// @notice Convert sUSDS back to USDT through USDS and USDC.
    function _convertCollateralToAsset(
        uint256 amount,
        uint256 amountOutMin
    ) internal override returns (uint256) {
        if (amount == 0) return 0;

        uint256 usdsAmount = IERC4626(collateralToken).redeem(
            amount,
            address(this),
            address(this)
        );
        uint256 usdcAmount = usdsAmount / USDS_TO_USDC_SCALE;
        require(usdcAmount > 0, "slippage");

        ILitePSMWrapper(LITE_PSM_WRAPPER).buyGem(address(this), usdcAmount);

        uint256 usdtAmount = _swapFrom(
            USDC,
            address(asset),
            usdcAmount,
            amountOutMin
        );
        require(usdtAmount >= amountOutMin, "slippage");
        return usdtAmount;
    }

    /*//////////////////////////////////////////////////////////////
                        NO-OP REWARDS (NONE)
    //////////////////////////////////////////////////////////////*/

    function _claimAndSellRewards() internal pure override {}
}
