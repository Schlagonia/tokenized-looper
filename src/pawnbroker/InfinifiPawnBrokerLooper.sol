// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PawnBrokerLooper} from "./PawnBrokerLooper.sol";
import {IInfiniFiGatewayV1} from "../interfaces/infinifi/IInfiniFiGatewayV1.sol";

/// @notice Pawn broker looper using sIUSD as collateral and USDC as the borrow asset.
contract InfinifiPawnBrokerLooper is PawnBrokerLooper {
    using SafeERC20 for ERC20;

    address public constant IUSD = 0x48f9e38f3070AD8945DFEae3FA70987722E3D89c;
    address public constant SIUSD = 0xDBDC1Ef57537E34680B898E1FEBD3D68c7389bCB;
    address public constant GATEWAY =
        0x3f04b65Ddbd87f9CE0A2e7Eb24d80e7fb87625b5;

    constructor(
        address _asset,
        string memory _name,
        address _pawnBroker,
        address _morpho,
        address _governance
    )
        PawnBrokerLooper(
            _asset,
            _name,
            SIUSD,
            _morpho,
            _pawnBroker,
            address(0),
            _governance
        )
    {
        ERC20(_asset).forceApprove(GATEWAY, type(uint256).max);
        ERC20(IUSD).forceApprove(GATEWAY, type(uint256).max);
        ERC20(SIUSD).forceApprove(GATEWAY, type(uint256).max);
        minAmountToBorrow = 0;
        slippage = 1;
    }

    function _convertAssetToCollateral(
        uint256 amount
    ) internal virtual override returns (uint256) {
        if (amount == 0) return 0;

        _updateSlippageLossLimit();
        uint256 collateralBalance = balanceOfCollateralToken();
        IInfiniFiGatewayV1(GATEWAY).mintAndStake(address(this), amount);
        uint256 amountOut = balanceOfCollateralToken() - collateralBalance;
        _recordSlippage(amount, _collateralToAsset(amountOut));
        return amountOut;
    }

    function _convertCollateralToAsset(
        uint256 amount
    ) internal virtual override returns (uint256) {
        if (amount == 0) return 0;

        _updateSlippageLossLimit();
        uint256 iusdBalance = IInfiniFiGatewayV1(GATEWAY).unstake(
            address(this),
            amount
        );

        uint256 amountOut = IInfiniFiGatewayV1(GATEWAY).redeem(
            address(this),
            iusdBalance,
            0
        );
        _recordSlippage(_collateralToAsset(amount), amountOut);
        return amountOut;
    }

    function claimRedemption() external onlyKeepers {
        IInfiniFiGatewayV1(GATEWAY).claimRedemption();
    }
}
