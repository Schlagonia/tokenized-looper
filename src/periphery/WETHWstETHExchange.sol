// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseExchange} from "./BaseExchange.sol";
import {ISteth, ICurveFi, IWETH, IwstETH} from "../interfaces/IStethInterfaces.sol";

/**
 * @title WETHWstETHExchange
 * @notice Strategy-bound exchange for WETH <-> wstETH conversions using Lido/Curve.
 *         Path:
 *         - WETH -> ETH -> stETH (Curve or Lido mint) -> wstETH
 *         - wstETH -> stETH -> ETH (Curve) -> WETH
 */
contract WETHWstETHExchange is BaseExchange {
    using SafeERC20 for ERC20;

    /// @notice Borrow asset token (WETH) for this fixed exchange path.
    address public constant ASSET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Collateral token (wstETH) for this fixed exchange path.
    address public constant COLLATERAL =
        0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    ICurveFi public constant STABLE_SWAP_STETH =
        ICurveFi(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);

    ISteth public constant STETH =
        ISteth(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

    address internal constant REFERRAL =
        0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;

    int128 internal constant WETH_ID = 0;
    int128 internal constant STETH_ID = 1;

    constructor() {
        ERC20(address(STETH)).forceApprove(
            address(STABLE_SWAP_STETH),
            type(uint256).max
        );
        ERC20(address(STETH)).forceApprove(COLLATERAL, type(uint256).max);
    }

    receive() external payable {}

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal override returns (uint256 amountOut) {
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
        uint256 amountOutMin
    ) internal returns (uint256 amountOut) {
        IWETH(ASSET).withdraw(amountIn);

        uint256 collateralBefore = ERC20(COLLATERAL).balanceOf(address(this));
        uint256 curveOut = STABLE_SWAP_STETH.get_dy(
            WETH_ID,
            STETH_ID,
            amountIn
        );

        if (curveOut < amountIn) {
            STETH.submit{value: amountIn}(REFERRAL);
        } else {
            STABLE_SWAP_STETH.exchange{value: amountIn}(
                WETH_ID,
                STETH_ID,
                amountIn,
                Math.max(amountOutMin, amountIn)
            );
        }

        IwstETH(COLLATERAL).wrap(STETH.balanceOf(address(this)));
        amountOut =
            ERC20(COLLATERAL).balanceOf(address(this)) -
            collateralBefore;
    }

    function _swapCollateralToAsset(
        uint256 amountIn,
        uint256 amountOutMin
    ) internal returns (uint256 amountOut) {
        uint256 assetBefore = ERC20(ASSET).balanceOf(address(this));

        uint256 stEthAmount = IwstETH(COLLATERAL).unwrap(amountIn);
        STABLE_SWAP_STETH.exchange(
            STETH_ID,
            WETH_ID,
            stEthAmount,
            amountOutMin
        );

        IWETH(ASSET).deposit{value: address(this).balance}();
        amountOut = ERC20(ASSET).balanceOf(address(this)) - assetBefore;
    }
}
