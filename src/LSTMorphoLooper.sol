// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseMorphoLooper} from "./BaseMorphoLooper.sol";
import {Id} from "./interfaces/morpho/IMorpho.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

/**
 * @notice LSTMorphoLooper is a looper that is built to use any token as collateral to
 *         leveragae loop against its underlying asset.
 *         It uses Uniswap V3 to swap the collateral to the underlying asset and back.
 */
contract LSTMorphoLooper is BaseMorphoLooper, UniswapV3Swapper {
    using SafeERC20 for ERC20;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId,
        address _router
    ) BaseMorphoLooper(_asset, _name, _collateralToken, _morpho, _marketId) {
        _setUniFees(address(asset), address(collateralToken), 100);
        router = _router;
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

    /*//////////////////////////////////////////////////////////////
                            CONVERSIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert asset to collateral token via Uniswap V3
    /// @dev Swaps asset (e.g., WETH) to collateral (e.g., wstETH) using configured Uniswap V3 pool.
    /// @param amount The amount of asset to convert
    /// @param amountOutMin The minimum amount of collateral to receive (slippage protection)
    /// @return The amount of collateral tokens received
    function _convertAssetToCollateral(
        uint256 amount,
        uint256 amountOutMin
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        return
            _swapFrom(
                address(asset),
                address(collateralToken),
                amount,
                amountOutMin
            );
    }

    /// @notice Convert collateral token back to asset via Uniswap V3
    /// @dev Swaps collateral (e.g., wstETH) to asset (e.g., WETH) using configured Uniswap V3 pool.
    /// @param amount The amount of collateral to convert
    /// @param amountOutMin The minimum amount of asset to receive (slippage protection)
    /// @return The amount of asset tokens received
    function _convertCollateralToAsset(
        uint256 amount,
        uint256 amountOutMin
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        return
            _swapFrom(
                address(collateralToken),
                address(asset),
                amount,
                amountOutMin
            );
    }

    /*//////////////////////////////////////////////////////////////
                        NO-OP REWARDS (NONE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim and sell protocol rewards
    /// @dev No rewards to claim for LST positions. Override if rewards become available.
    function _claimAndSellRewards() internal pure override {}
}
