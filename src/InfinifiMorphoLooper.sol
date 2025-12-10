// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseMorphoLooper} from "./BaseMorphoLooper.sol";
import {Id} from "./interfaces/morpho/IMorpho.sol";
import {IInfiniFiGatewayV1} from "./interfaces/infinifi/IInfiniFiGatewayV1.sol";

/**
 * @notice Infinifi/Morpho looper using sIUSD (staked iUSD) as collateral and USDC as borrow token.
 *         Uses flashloan-based leverage for atomic position management.
 *         - Deposits USDC -> mints iUSD -> stakes to sIUSD via GatewayV1.
 *         - Withdraws sIUSD -> redeems to iUSD -> redeems to USDC.
 *         - Uses the provided Morpho Blue marketId (collateral = sIUSD, borrow = USDC).
 */
contract InfinifiMorphoLooper is BaseMorphoLooper {
    using SafeERC20 for ERC20;

    /// @notice Infinifi gateway V1 (proxy address on mainnet).
    address public immutable gateway;

    /// @notice iUSD receipt token (12 decimals).
    address public immutable iusd;

    constructor(
        address _asset, // USDC
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId,
        address _gateway,
        address _iusd
    ) BaseMorphoLooper(_asset, _name, _collateralToken, _morpho, _marketId) {
        gateway = _gateway;
        iusd = _iusd;

        // Approvals for gateway and Morpho.
        ERC20(_asset).forceApprove(_gateway, type(uint256).max);
        ERC20(_iusd).forceApprove(_gateway, type(uint256).max);
        ERC20(_collateralToken).forceApprove(_gateway, type(uint256).max);

        minAmountToBorrow = 0; // allow small loops; Morpho caps still apply.
        slippage = 1; // no slippage
    }

    /*//////////////////////////////////////////////////////////////
                            CONVERSIONS
    //////////////////////////////////////////////////////////////*/

    function _convertAssetToCollateral(
        uint256 amount
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        // Gateway mints iUSD and stakes directly to sIUSD for this contract.
        uint256 collateralBalance = balanceOfCollateralToken();
        IInfiniFiGatewayV1(gateway).mintAndStake(address(this), amount);
        return balanceOfCollateralToken() - collateralBalance;
    }

    function _convertCollateralToAsset(
        uint256 amount
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        uint256 iusdBalance = IInfiniFiGatewayV1(gateway).unstake(
            address(this),
            amount
        );
        // Gateway handles unstake + redemption back to USDC.
        return
            IInfiniFiGatewayV1(gateway).redeem(address(this), iusdBalance, 0);
    }

    /// @notice Get oracle price in ORACLE_PRICE_SCALE (1e36)
    /// @dev sIUSD (18 decimals) -> USDC (6 decimals)
    ///      convertToAssets(1e18) returns USDC value of 1 sIUSD in 18 decimals
    ///      We need: price * collateralAmount / 1e36 = assetAmount
    ///      So price = assetAmount * 1e36 / collateralAmount
    ///      For 1 sIUSD (1e18): price = convertToAssets(1e18) * 1e36 / 1e18 / 1e12
    ///      Simplified: convertToAssets(1e18) * 1e24 / 1e12 = convertToAssets(1e18) * 1e6
    function _getCollateralPrice() internal view override returns (uint256) {
        return IERC4626(collateralToken).convertToAssets(1e18) * 1e6;
    }

    /*//////////////////////////////////////////////////////////////
                        NO-OP REWARDS (NONE)
    //////////////////////////////////////////////////////////////*/

    function _claimAndSellRewards() internal pure override {}
}
