// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MorphoLooper} from "./MorphoLooper.sol";
import {Id} from "../interfaces/morpho/IMorpho.sol";
import {IInfiniFiGatewayV1} from "../interfaces/infinifi/IInfiniFiGatewayV1.sol";
import {IRedeemController} from "../interfaces/infinifi/IRedeemController.sol";

/**
 * @notice Infinifi/Morpho looper using sIUSD (staked iUSD) as collateral and USDC as borrow token.
 *         Uses flashloan-based leverage for atomic position management.
 *         - Deposits USDC -> mints iUSD -> stakes to sIUSD via GatewayV1.
 *         - Withdraws sIUSD -> redeems to iUSD -> redeems to USDC.
 *         - Uses the provided Morpho Blue marketId (collateral = sIUSD, borrow = USDC).
 */
contract InfinifiMorphoLooper is MorphoLooper {
    using SafeERC20 for ERC20;

    /// @notice iUSD receipt token.
    address public constant IUSD = 0x48f9e38f3070AD8945DFEae3FA70987722E3D89c;

    /// @notice Infinifi gateway V1 (proxy address on mainnet).
    address public constant GATEWAY =
        0x3f04b65Ddbd87f9CE0A2e7Eb24d80e7fb87625b5;

    /// @notice USDC assets queued in InfiniFi's redemption controller.
    uint256 public pendingRedemptions;

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
            address(0),
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

    /// @notice Convert USDC to sIUSD (staked iUSD) via Infinifi Gateway
    /// @dev Uses gateway.mintAndStake to atomically mint iUSD from USDC and stake it to sIUSD.
    /// @param amount The amount of USDC to convert
    /// @return The amount of sIUSD received
    function _convertAssetToCollateral(
        uint256 amount
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        _updateSlippageLossLimit();
        // Gateway mints iUSD and stakes directly to sIUSD for this contract.
        uint256 collateralBalance = balanceOfCollateralToken();
        IInfiniFiGatewayV1(GATEWAY).mintAndStake(address(this), amount);
        uint256 amountOut = balanceOfCollateralToken() - collateralBalance;
        _recordSlippage(amount, _collateralToAsset(amountOut));
        return amountOut;
    }

    /// @notice Convert sIUSD (staked iUSD) back to USDC via Infinifi Gateway
    /// @dev First unstakes sIUSD to iUSD, then redeems iUSD for USDC via the gateway.
    /// @param amount The amount of sIUSD to convert
    /// @return The amount of USDC received
    function _convertCollateralToAsset(
        uint256 amount
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        _updateSlippageLossLimit();
        uint256 iusdBalance = IInfiniFiGatewayV1(GATEWAY).unstake(
            address(this),
            amount
        );
        // Gateway handles unstake + redemption back to USDC.
        uint256 amountOut = IInfiniFiGatewayV1(GATEWAY).redeem(
            address(this),
            iusdBalance,
            0
        );
        _recordSlippage(_collateralToAsset(amount), amountOut);
        return amountOut;
    }

    /// @notice Queue loose sIUSD for nonatomic redemption through InfiniFi.
    function initiateRedemption(
        uint256 shares
    ) external onlyManagement returns (uint256 assetsOut, uint256 queuedAssets) {
        require(pendingRedemptions == 0, "pending redemptions");

        uint256 balance = balanceOfCollateralToken();
        if (shares > balance) shares = balance;
        require(shares > 0, "!shares");

        uint256 iusdAmount = IInfiniFiGatewayV1(GATEWAY).unstake(
            address(this),
            shares
        );
        uint256 expectedAssets = _redeemController().receiptToAsset(
            iusdAmount
        );

        uint256 preBalance = asset.balanceOf(address(this));
        IInfiniFiGatewayV1(GATEWAY).redeem(address(this), iusdAmount, 0);
        assetsOut = asset.balanceOf(address(this)) - preBalance;

        if (expectedAssets > assetsOut) {
            queuedAssets = expectedAssets - assetsOut;
            pendingRedemptions = queuedAssets;
        }
    }

    /// @notice Claim any enqueued redemptions from InfiniFi.
    function claimRedemption() external onlyKeepers returns (uint256 assets) {
        uint256 claimable = _redeemController().userPendingClaims(
            address(this)
        );
        require(claimable > 0, "!claim");

        uint256 preBalance = asset.balanceOf(address(this));
        IInfiniFiGatewayV1(GATEWAY).claimRedemption();
        assets = asset.balanceOf(address(this)) - preBalance;
        require(assets > 0, "!assets");

        if (assets >= pendingRedemptions) {
            delete pendingRedemptions;
        } else {
            unchecked {
                pendingRedemptions -= assets;
            }
        }
    }

    function zeroPendingRedemptions() external onlyManagement {
        delete pendingRedemptions;
    }

    function protectedTokens()
        public
        view
        override
        returns (address[] memory _protected)
    {
        _protected = new address[](3);
        _protected[0] = address(asset);
        _protected[1] = collateralToken;
        _protected[2] = IUSD;
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return super.estimatedTotalAssets() + pendingRedemptions;
    }

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        require(pendingRedemptions == 0, "pending redemptions");
        return super._harvestAndReport();
    }

    function _redeemController()
        internal
        view
        returns (IRedeemController)
    {
        return
            IRedeemController(
                IInfiniFiGatewayV1(GATEWAY).getAddress("redeemController")
            );
    }

    /*//////////////////////////////////////////////////////////////
                        NO-OP REWARDS (NONE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim and sell protocol rewards
    /// @dev No rewards to claim for Infinifi positions. Override if rewards become available.
    function _claimAndSellRewards() internal pure override {}
}
