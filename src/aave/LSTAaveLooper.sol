// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseAaveLooper} from "./BaseAaveLooper.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

/**
 * @title LSTAaveLooper
 * @notice Aave V3 looper that uses any LST token as collateral to
 *         leverage loop against its underlying asset.
 *         It uses Uniswap V3 to swap the collateral to the underlying asset and back.
 * @dev Example: Use wstETH as collateral, borrow WETH, swap to wstETH, repeat.
 *      E-Mode category 1 is typically ETH-correlated assets on Aave V3.
 */
contract LSTAaveLooper is BaseAaveLooper, UniswapV3Swapper {
    using SafeERC20 for ERC20;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _addressesProvider,
        uint8 _eModeCategoryId,
        address _router
    )
        BaseAaveLooper(
            _asset,
            _name,
            _collateralToken,
            _addressesProvider,
            _eModeCategoryId
        )
    {
        // Set default Uniswap fee (100 = 0.01% for highly correlated assets like wstETH/WETH)
        _setUniFees(address(asset), collateralToken, 100);
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

    function _convertAssetToCollateral(
        uint256 amount,
        uint256 amountOutMin
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        return _swapFrom(address(asset), collateralToken, amount, amountOutMin);
    }

    function _convertCollateralToAsset(
        uint256 amount,
        uint256 amountOutMin
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        return _swapFrom(collateralToken, address(asset), amount, amountOutMin);
    }
}
