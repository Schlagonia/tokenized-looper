// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseMorphoLooper} from "./BaseMorphoLooper.sol";
import {Id} from "./interfaces/morpho/IMorpho.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

/**
 * @notice VaultMorphoLooper is a looper that is built to use any token as collateral to
 *         leveragae loop against its underlying asset.
 *         It uses Uniswap V3 to swap the collateral to the underlying asset and back.
 */
contract VaultMorphoLooper is BaseMorphoLooper, UniswapV3Swapper {
    using SafeERC20 for ERC20;

    address public immutable vaultAsset;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId,
        address _router
    ) BaseMorphoLooper(_asset, _name, _collateralToken, _morpho, _marketId) {
        vaultAsset = IERC4626(_collateralToken).asset();
        _setUniFees(address(asset), address(vaultAsset), 100);
        router = _router;

        ERC20(vaultAsset).forceApprove(_collateralToken, type(uint256).max);
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

    function _convertAssetToCollateral(
        uint256 amount
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        // Swap to underly asset then deposit into vault
        uint256 amountOut = _swapFrom(address(asset), address(vaultAsset), amount, 0);
        return IERC4626(collateralToken).deposit(amountOut, address(this));
    }

    function _convertCollateralToAsset(
        uint256 amount
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        // Redeem from vault then swap to asset
        uint256 amountOut = IERC4626(collateralToken).redeem(amount, address(this), address(this));
        return _swapFrom(address(vaultAsset), address(asset), amountOut, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        NO-OP REWARDS (NONE)
    //////////////////////////////////////////////////////////////*/

    function _claimAndSellRewards() internal pure override {}
}
