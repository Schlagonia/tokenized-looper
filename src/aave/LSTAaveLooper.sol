// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AaveLooper} from "./AaveLooper.sol";
import {ISteth, IQueue, IWETH, IwstETH} from "../interfaces/IStethInterfaces.sol";

/**
 * @title LSTAaveLooper
 * @notice Aave V3 looper that uses any LST token as collateral to
 *         leverage loop against its underlying asset.
 *         It uses Uniswap V3 to swap the collateral to the underlying asset and back.
 * @dev Example: Use wstETH as collateral, borrow WETH, swap to wstETH, repeat.
 *      E-Mode category 1 is typically ETH-correlated assets on Aave V3.
 */
contract LSTAaveLooper is AaveLooper {
    using SafeERC20 for *;

    /// @notice Shares queued for direct Lido withdrawals.
    uint256 public pendingRedemptions;

    IQueue internal constant WITHDRAWAL_QUEUE =
        IQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1); // stETH withdrawal queue
    ISteth internal constant STETH =
        ISteth(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

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
        require(pendingRedemptions == 0, "pending redemptions");
        return super._harvestAndReport();
    }

    /// @notice Initiate stETH withdrawal through Lido queue for 1:1 redemption
    /// @param _amount Amount of LST to queue for withdrawal
    /// @return nftId Withdrawal ID number from the withdrawal request
    function initiateLSTWithdrawal(
        uint256 _amount
    ) external onlyEmergencyAuthorized returns (uint256) {
        uint256 collateralBalance = balanceOfCollateralToken();
        if (_amount > collateralBalance) _amount = collateralBalance;
        uint256 stETHAmount = IwstETH(address(collateralToken)).unwrap(_amount);

        pendingRedemptions += stETHAmount;

        STETH.forceApprove(address(WITHDRAWAL_QUEUE), stETHAmount);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = stETHAmount;

        return WITHDRAWAL_QUEUE.requestWithdrawals(amounts, address(this))[0];
    }

    /// @notice Claim ETH from completed Lido withdrawal request
    /// @param _claimId The claim ID from the withdrawal request
    /// @return _redeemedAmount Amount of LST redeemed
    function claimLSTWithdrawal(
        uint256 _claimId
    ) external onlyEmergencyAuthorized returns (uint256) {
        uint256 preBalance = address(this).balance;
        WITHDRAWAL_QUEUE.claimWithdrawal(_claimId);
        uint256 redeemedAmount = address(this).balance - preBalance;
        if (redeemedAmount >= pendingRedemptions) {
            delete pendingRedemptions;
        } else {
            pendingRedemptions -= redeemedAmount;
        }
        _wrapEthBalance();
        return redeemedAmount;
    }

    /// @notice Manually zero the pending redemptions in case of significant dust or a Lido slashing event.
    /// @dev Only may be called by governance.
    function zeroPendingRedemptions() external onlyEmergencyAuthorized {
        delete pendingRedemptions;
    }

    function _wrapEthBalance() private {
        IWETH(address(asset)).deposit{value: address(this).balance}();
    }
}
