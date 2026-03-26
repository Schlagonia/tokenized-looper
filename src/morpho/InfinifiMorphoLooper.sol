// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MorphoLooper} from "./MorphoLooper.sol";
import {Id} from "../interfaces/morpho/IMorpho.sol";
import {IInfiniFiGatewayV1} from "../interfaces/infinifi/IInfiniFiGatewayV1.sol";

/**
 * @notice Infinifi/Morpho looper using sIUSD (staked iUSD) as collateral and USDC as borrow token.
 *         Uses flashloan-based leverage for atomic position management.
 *         - Deposits USDC -> mints iUSD -> stakes to sIUSD via GatewayV1.
 *         - Withdraws sIUSD -> redeems to iUSD -> redeems to USDC.
 *         - Uses the provided Morpho Blue marketId (collateral = sIUSD, borrow = USDC).
 */
contract InfinifiMorphoLooper is MorphoLooper {
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
        Id _marketId,
        address _governance
    )
        MorphoLooper(
            _asset,
            _name,
            _collateralToken,
            _morpho,
            _marketId,
            _governance
        )
    {
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

    function _executeSwap(
        address from,
        address to,
        uint256 amount,
        uint256 amountOutMin,
        bytes memory swapData
    ) internal override returns (uint256) {
        if (from != collateralToken || to != address(asset)) {
            return super._executeSwap(from, to, amount, amountOutMin, swapData);
        }
        if (amount == 0) return 0;
        uint256 iusdBalance = IInfiniFiGatewayV1(GATEWAY).unstake(
            address(this),
            amount
        );
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
