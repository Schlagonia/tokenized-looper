// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AaveLooper} from "./AaveLooper.sol";
import {LidoWithdrawalHelper} from "./LidoWithdrawalHelper.sol";
import {IwstETH} from "../interfaces/IStethInterfaces.sol";

/**
 * @title LSTAaveLooper
 * @notice Aave V3 looper that uses any LST token as collateral to
 *         leverage loop against its underlying asset.
 *         It uses Uniswap V3 to swap the collateral to the underlying asset and back.
 * @dev Example: Use wstETH as collateral, borrow WETH, swap to wstETH, repeat.
 *      E-Mode category 1 is typically ETH-correlated assets on Aave V3.
 */
contract LSTAaveLooper is AaveLooper {
    using SafeERC20 for ERC20;

    /// @notice Shares queued for direct Lido withdrawals.
    uint256 public pendingRedemptions;
    LidoWithdrawalHelper internal immutable LIDO_HELPER;
    address internal constant STETH =
        0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _addressesProvider,
        address _morpho,
        uint8 _eModeCategoryId,
        address _governance
    )
        AaveLooper(
            _asset,
            _name,
            _collateralToken,
            _addressesProvider,
            _morpho,
            _eModeCategoryId,
            _governance
        )
    {
        LIDO_HELPER = new LidoWithdrawalHelper(address(this), _asset);
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return super.estimatedTotalAssets() + pendingRedemptions;
    }

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        require(pendingRedemptions == 0, "pending");
        return super._harvestAndReport();
    }

    /// @notice Initiate stETH withdrawal through Lido queue for 1:1 redemption
    /// @param _amount Amount of LST to queue for withdrawal
    /// @return nftId Withdrawal ID number from the withdrawal request
    function initiateLSTWithdrawal(
        uint256 _amount
    ) external onlyEmergencyAuthorized returns (uint256 nftId) {
        _amount = Math.min(_amount, balanceOfCollateralToken());
        uint256 stETHAmount = IwstETH(address(collateralToken)).unwrap(_amount);

        pendingRedemptions += stETHAmount;
        ERC20(STETH).safeTransfer(address(LIDO_HELPER), stETHAmount);
        return LIDO_HELPER.initiate(stETHAmount);
    }

    /// @notice Claim ETH from completed Lido withdrawal request
    /// @param _claimId The claim ID from the withdrawal request
    /// @return _redeemedAmount Amount of LST redeemed
    function claimLSTWithdrawal(
        uint256 _claimId
    ) external onlyEmergencyAuthorized returns (uint256 _redeemedAmount) {
        _redeemedAmount = LIDO_HELPER.claim(_claimId, address(this));
        pendingRedemptions = _redeemedAmount >= pendingRedemptions
            ? 0
            : pendingRedemptions - _redeemedAmount;
    }

    /// @notice Manually zero the pending redemptions in case of significant dust or a Lido slashing event.
    /// @dev Only may be called by governance.
    function zeroPendingRedemptions() external onlyEmergencyAuthorized {
        pendingRedemptions = 0;
    }
}
