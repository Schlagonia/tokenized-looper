// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AaveLooper} from "./AaveLooper.sol";
import {EthenaCooldownLib} from "../libraries/EthenaCooldownLib.sol";

/**
 * @title sUSDeAaveLooper
 * @notice Aave V3 looper that uses sUSDe as collateral to Leverage loop
 * @dev Example: Use sUSDe as collateral, borrow USDT/USDC, swap to sUSDe, repeat.
 */
contract sUSDeAaveLooper is AaveLooper {
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

    function estimatedTotalAssets() public view override returns (uint256) {
        return
            super.estimatedTotalAssets() +
            _collateralToAsset(
                IERC4626(address(collateralToken)).convertToShares(
                    pendingRedemptions + balanceOfUnderlying()
                )
            );
    }

    function balanceOfUnderlying() public view returns (uint256) {
        return EthenaCooldownLib.balanceOfUnderlying();
    }

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        require(pendingRedemptions == 0, "pending redemptions");
        return super._harvestAndReport();
    }

    /// @notice Initiate sUSDe cooldown
    /// @param _shares Amount of shares to queue for cooldown
    /// @return assets Amount of assets cooldowned
    function initiateCooldown(
        uint256 _shares
    ) external onlyManagement returns (uint256 assets) {
        // New Cooldowns will override existing ones so dont allow till cleared
        require(pendingRedemptions == 0, "pending redemptions");
        _shares = Math.min(_shares, balanceOfCollateralToken());

        assets = EthenaCooldownLib.initiate(_shares);
        pendingRedemptions = assets;
    }

    /// @notice Claim cooldowned assets
    function claimCooldown() external onlyKeepers {
        EthenaCooldownLib.claim();
        pendingRedemptions = 0;
    }

    /// @notice Manually zero the pending cooldowns in case of significant dust or a cooldown event.
    /// @dev Only may be called by governance.
    function zeroPendingRedemptions() external onlyManagement {
        pendingRedemptions = 0;
    }

    function convertUnderlyingToAsset(
        uint256 amount
    ) public onlyKeepers returns (uint256) {
        (uint256 shares, uint256 amountOut) = EthenaCooldownLib
            .convertUnderlyingToAsset(amount, exchange, address(asset));

        _recordSlippage(_collateralToAsset(shares), amountOut);
        return amountOut;
    }
}
