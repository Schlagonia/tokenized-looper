// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AaveLooper} from "./AaveLooper.sol";
import {IsUSDe} from "../interfaces/IsUSDe.sol";
/**
 * @title sUSDeAaveLooper
 * @notice Aave V3 looper that uses sUSDe as collateral to
 *         leverage loop against its underlying asset.
 *         It uses Uniswap V3 to swap the collateral to the underlying asset and back.
 * @dev Example: Use sUSDe as collateral, borrow USDe/USDC, swap to sUSDe, repeat.
 */
contract sUSDeAaveLooper is AaveLooper {
    using SafeERC20 for *;

    /// @notice Shares queued for cooldowns.
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
        return
            super.estimatedTotalAssets() +
            _collateralToAsset(pendingRedemptions);
    }

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        require(pendingRedemptions == 0, "pending redemptions");
        return super._harvestAndReport();
    }

    /// @notice Initiate ssUSDe cooldown
    /// @param _shares Amount of shares to queue for cooldown
    /// @return assets Amount of assets cooldowned
    function initiateCooldown(
        uint256 _shares
    ) external onlyEmergencyAuthorized returns (uint256 assets) {
        // New Cooldowns will override existing ones so dont allow till cleared
        require(pendingRedemptions == 0, "pending redemptions");
        _shares = Math.min(_shares, balanceOfCollateralToken());

        assets = IsUSDe(address(collateralToken)).cooldownShares(_shares);
        pendingRedemptions += _shares;
    }

    /// @notice Claim cooldowned assets
    function claimCooldown() external onlyEmergencyAuthorized {
        IsUSDe(address(collateralToken)).unstake(address(this));
        pendingRedemptions = 0;
    }

    /// @notice Manually zero the pending cooldowns in case of significant dust or a cooldown event.
    /// @dev Only may be called by governance.
    function zeroPendingRedemptions() external onlyEmergencyAuthorized {
        pendingRedemptions = 0;
    }
}
