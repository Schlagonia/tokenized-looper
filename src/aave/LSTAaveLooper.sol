// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {AaveLooper} from "./AaveLooper.sol";
import {LidoWithdrawalLib} from "../libraries/LidoWithdrawalLib.sol";

/**
 * @title LSTAaveLooper
 * @notice Aave V3 looper that uses any LST token as collateral to
 *         leverage loop against its underlying asset.
 *         It uses Uniswap V3 to swap the collateral to the underlying asset and back.
 * @dev Example: Use wstETH as collateral, borrow WETH, swap to wstETH, repeat.
 *      E-Mode category 1 is typically ETH-correlated assets on Aave V3.
 */
contract LSTAaveLooper is AaveLooper {
    /// @notice Shares queued for direct Lido withdrawals.
    uint256 public pendingRedemptions;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _addressesProvider,
        address _morpho,
        uint8 _eModeCategoryId,
        address _exchange,
        address _governance
    )
        AaveLooper(
            _asset,
            _name,
            _collateralToken,
            _addressesProvider,
            _morpho,
            _eModeCategoryId,
            _exchange,
            _governance
        )
    {}

    receive() external payable {}

    function estimatedTotalAssets() public view override returns (uint256) {
        return super.estimatedTotalAssets() + pendingRedemptions;
    }

    function _harvestAndReport() internal override returns (uint256) {
        require(pendingRedemptions == 0);
        return super._harvestAndReport();
    }

    /// @notice Initiate stETH withdrawal through Lido queue for 1:1 redemption
    /// @param _amount Amount of LST to queue for withdrawal
    /// @return nftId Withdrawal ID number from the withdrawal request
    function initiateLSTWithdrawal(
        uint256 _amount
    ) external payable onlyEmergencyAuthorized returns (uint256 nftId) {
        uint256 pendingAssets;
        (nftId, pendingAssets) = LidoWithdrawalLib.initiate(_amount);
        unchecked {
            pendingRedemptions += pendingAssets;
        }
    }

    /// @notice Claim ETH from completed Lido withdrawal request
    /// @param _claimId The claim ID from the withdrawal request
    /// @return assets Amount of LST redeemed
    function claimLSTWithdrawal(
        uint256 _claimId
    ) external payable onlyEmergencyAuthorized returns (uint256 assets) {
        assets = LidoWithdrawalLib.claim(_claimId);
        if (assets >= pendingRedemptions) {
            delete pendingRedemptions;
        } else {
            unchecked {
                pendingRedemptions -= assets;
            }
        }
    }

    /// @notice Manually zero pending redemptions in exceptional scenarios.
    function zeroPendingRedemptions() external payable onlyEmergencyAuthorized {
        delete pendingRedemptions;
    }
}
