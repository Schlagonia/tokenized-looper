// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MorphoLooper} from "./MorphoLooper.sol";
import {Id} from "../interfaces/morpho/IMorpho.sol";
import {ISyrupPool} from "../interfaces/syrup/ISyrupPool.sol";

/**
 * @title SyrupMorphoLooper
 * @notice Generic Morpho looper for syrup collateral markets where:
 *         - loanToken = underlying stablecoin (e.g. USDC/USDT)
 *         - collateralToken = matching syrup vault token (e.g. syrupUSDC/syrupUSDT)
 *         Primary conversion path delegates to an external exchange contract.
 */
contract SyrupMorphoLooper is MorphoLooper {
    /// @notice Shares queued for direct (async) redemption.
    uint256 public pendingRedemptionShares;

    constructor(
        address _asset,
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
    {}

    /// NOTE: This may be very over inflated post redemption fill but before pending is zeroed out.
    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 pendingAssets;
        if (pendingRedemptionShares > 0) {
            pendingAssets = ISyrupPool(collateralToken).convertToAssets(
                pendingRedemptionShares
            );
        }
        return super.estimatedTotalAssets() + pendingAssets;
    }

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        // Don't allow reports since we cannot guarantee the pending redemption shares are filled or not
        require(pendingRedemptionShares == 0, "pending");
        return super._harvestAndReport();
    }

    /*//////////////////////////////////////////////////////////////
                        DIRECT REDEMPTION PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Queue syrup shares for direct redemption.
    /// @dev asset is directly sent back to the strategy once filled
    function initiateDirectRedemption(
        uint256 _shares
    ) external onlyEmergencyAuthorized returns (uint256 _exitShares) {
        _shares = Math.min(_shares, balanceOfCollateralToken());
        require(_shares > 0, "!shares");

        _exitShares = ISyrupPool(collateralToken).requestRedeem(
            _shares,
            address(this)
        );
        pendingRedemptionShares += _exitShares;
    }

    /// @notice Cancel queued redemption shares.
    function cancelDirectRedemption(
        uint256 _shares
    ) external onlyEmergencyAuthorized returns (uint256 _removedShares) {
        _shares = _shares == type(uint256).max
            ? pendingRedemptionShares
            : _shares;
        require(_shares > 0, "!shares");

        _removedShares = ISyrupPool(collateralToken).removeShares(
            _shares,
            address(this)
        );

        pendingRedemptionShares = _removedShares >= pendingRedemptionShares
            ? 0
            : pendingRedemptionShares - _removedShares;
    }

    /// @notice Manually clear pending redemptions.
    /// NOTE: Maple will automatically send usdc to the strategy. So this will
    ///       need to be called once done to allow reports to continue.
    function zeroPendingRedemptions() external onlyEmergencyAuthorized {
        pendingRedemptionShares = 0;
    }
}
