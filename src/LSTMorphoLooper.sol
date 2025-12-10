// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseMorphoLooper} from "./BaseMorphoLooper.sol";
import {Id} from "./interfaces/morpho/IMorpho.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

/**
 * @notice Infinifi/Morpho looper using sIUSD (staked iUSD) as collateral and USDC as borrow token.
 *         Uses flashloan-based leverage for atomic position management.
 *         - Deposits USDC -> mints iUSD -> stakes to sIUSD via GatewayV1.
 *         - Withdraws sIUSD -> redeems to iUSD -> redeems to USDC.
 *         - Uses the provided Morpho Blue marketId (collateral = sIUSD, borrow = USDC).
 */
contract LSTMorphoLooper is BaseMorphoLooper, UniswapV3Swapper {
    using SafeERC20 for ERC20;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId
    ) BaseMorphoLooper(_asset, _name, _collateralToken, _morpho, _marketId) {
        _setUniFees(address(asset), address(collateralToken), 100);
    }

    function setUniFees(
        address _token0,
        address _token1,
        uint24 _fee
    ) external onlyManagement {
        _setUniFees(_token0, _token1, _fee);
    }

    /*//////////////////////////////////////////////////////////////
                            CONVERSIONS
    //////////////////////////////////////////////////////////////*/

    function _convertAssetToCollateral(
        uint256 amount
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        // Gateway mints iUSD and stakes directly to sIUSD for this contract.
        return _swapFrom(address(asset), address(collateralToken), amount, 0);
    }

    function _convertCollateralToAsset(
        uint256 amount
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        // Add slippage to the amount in to make sure we get enough for the flash loan repayment.
        return _swapFrom(address(collateralToken), address(asset), amount, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        NO-OP REWARDS (NONE)
    //////////////////////////////////////////////////////////////*/

    function _claimAndSellRewards() internal pure override {}
}
