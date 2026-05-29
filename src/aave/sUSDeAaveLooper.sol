// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AaveLooper} from "./AaveLooper.sol";
import {IExchange} from "../interfaces/IExchange.sol";
import {IsUSDe} from "../interfaces/IsUSDe.sol";

/**
 * @title sUSDeAaveLooper
 * @notice Aave V3 looper that uses sUSDe as collateral to Leverage loop
 * @dev Example: Use sUSDe as collateral, borrow USDT/USDC, swap to sUSDe, repeat.
 */
contract sUSDeAaveLooper is AaveLooper {
    using SafeERC20 for ERC20;

    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant SUSDE =
        0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

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

    function totalCollateralBalance() public view override returns (uint256) {
        return
            super.totalCollateralBalance() +
            IERC4626(SUSDE).convertToShares(
                pendingRedemptions + balanceOfUnderlying()
            );
    }

    function balanceOfUnderlying() public view returns (uint256) {
        return ERC20(USDE).balanceOf(address(this));
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

        require(_shares > 0, "!shares");
        assets = IsUSDe(SUSDE).cooldownShares(_shares);
        pendingRedemptions = assets;
    }

    /// @notice Claim cooldowned assets
    function claimCooldown() external onlyKeepers {
        _claimCooldown();
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
        uint256 balance = ERC20(USDE).balanceOf(address(this));
        if (amount > balance) amount = balance;

        uint256 shares = IERC4626(SUSDE).convertToShares(amount);
        _updateSlippageLossLimit();
        ERC20(USDE).forceApprove(exchange, amount);
        uint256 amountOut = IExchange(exchange).exchange(
            USDE,
            address(asset),
            amount,
            0
        );

        _recordSlippage(_collateralToAsset(shares), amountOut);
        return amountOut;
    }

    function _claimCooldown() internal returns (uint256 assets) {
        uint256 preBalance = ERC20(USDE).balanceOf(address(this));
        IsUSDe(SUSDE).unstake(address(this));
        assets = ERC20(USDE).balanceOf(address(this)) - preBalance;
    }
}
