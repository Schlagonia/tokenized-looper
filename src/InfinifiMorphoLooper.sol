// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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

    /// @notice iUSD receipt token (12 decimals).
    address public constant IUSD = 0x48f9e38f3070AD8945DFEae3FA70987722E3D89c;

    /// @notice Infinifi gateway V1 (proxy address on mainnet).
    address public constant GATEWAY =
        0x3f04b65Ddbd87f9CE0A2e7Eb24d80e7fb87625b5;

    constructor(
        address _asset, // USDC
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId
    ) BaseMorphoLooper(_asset, _name, _collateralToken, _morpho, _marketId) {
        // Approvals for gateway and Morpho.
        ERC20(_asset).forceApprove(GATEWAY, type(uint256).max);
        ERC20(IUSD).forceApprove(GATEWAY, type(uint256).max);
        ERC20(_collateralToken).forceApprove(GATEWAY, type(uint256).max);

        minAmountToBorrow = 0; // allow small loops; Morpho caps still apply.
        slippage = 1; // just rounding losses
    }

    /*//////////////////////////////////////////////////////////////
                            CONVERSIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert USDC to sIUSD (staked iUSD) via Infinifi Gateway
    /// @dev Uses gateway.mintAndStake to atomically mint iUSD from USDC and stake it to sIUSD.
    ///      The amountOutMin parameter is unused since Infinifi provides 1:1 minting.
    /// @param amount The amount of USDC to convert
    /// @return The amount of sIUSD received
    function _convertAssetToCollateral(
        uint256 amount,
        uint256
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        // Gateway mints iUSD and stakes directly to sIUSD for this contract.
        uint256 collateralBalance = balanceOfCollateralToken();
        IInfiniFiGatewayV1(GATEWAY).mintAndStake(address(this), amount);
        return balanceOfCollateralToken() - collateralBalance;
    }

    /// @notice Convert sIUSD (staked iUSD) back to USDC via Infinifi Gateway
    /// @dev First unstakes sIUSD to iUSD, then redeems iUSD for USDC via the gateway.
    /// @param amount The amount of sIUSD to convert
    /// @param amountOutMin The minimum amount of USDC to receive (slippage protection)
    /// @return The amount of USDC received
    function _convertCollateralToAsset(
        uint256 amount,
        uint256 amountOutMin
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        uint256 iusdBalance = IInfiniFiGatewayV1(GATEWAY).unstake(
            address(this),
            amount
        );
        // Gateway handles unstake + redemption back to USDC.
        return
            IInfiniFiGatewayV1(GATEWAY).redeem(
                address(this),
                iusdBalance,
                amountOutMin
            );
    }

    /// @notice Claim any enqueued redemptions from Infinifi
    /// @dev Called by keepers if a redemption was delayed and enqueued by the gateway.
    function claimRedemption() external onlyEmergencyAuthorized {
        IInfiniFiGatewayV1(GATEWAY).claimRedemption();
    }

    /*//////////////////////////////////////////////////////////////
                        NO-OP REWARDS (NONE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim and sell protocol rewards
    /// @dev No rewards to claim for Infinifi positions. Override if rewards become available.
    function _claimAndSellRewards() internal pure override {}
}
