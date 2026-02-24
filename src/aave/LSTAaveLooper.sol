// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseAaveLooper} from "./BaseAaveLooper.sol";
import {ISteth, IQueue, IWETH, ICurveFi, IwstETH} from "../interfaces/IStethInterfaces.sol";

/**
 * @title LSTAaveLooper
 * @notice Aave V3 looper that uses any LST token as collateral to
 *         leverage loop against its underlying asset.
 *         It uses Uniswap V3 to swap the collateral to the underlying asset and back.
 * @dev Example: Use wstETH as collateral, borrow WETH, swap to wstETH, repeat.
 *      E-Mode category 1 is typically ETH-correlated assets on Aave V3.
 */
contract LSTAaveLooper is BaseAaveLooper {
    using SafeERC20 for *;

    // new stuff for redemptions
    uint256 public pendingRedemptions;
    IQueue internal constant WITHDRAWAL_QUEUE =
        IQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1); // stETH withdrawal queue

    ICurveFi public constant StableSwapSTETH =
        ICurveFi(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);

    ISteth public constant stETH =
        ISteth(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

    address internal constant REFERRAL =
        0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;

    // stETH specific constants
    int128 internal constant WETHID = 0;
    int128 internal constant STETHID = 1;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _addressesProvider,
        address _morpho,
        uint8 _eModeCategoryId
    )
        BaseAaveLooper(
            _asset,
            _name,
            _collateralToken,
            _addressesProvider,
            _morpho,
            _eModeCategoryId
        )
    {
        stETH.approve(address(StableSwapSTETH), type(uint256).max);
        stETH.forceApprove(_collateralToken, type(uint256).max);
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                            CONVERSIONS
    //////////////////////////////////////////////////////////////*/

    function _convertAssetToCollateral(
        uint256 amount,
        uint256 amountOutMin
    ) internal override returns (uint256) {
        if (amount == 0) return 0;

        IWETH(address(asset)).withdraw(amount);

        //test if we should buy instead of mint
        uint256 out = StableSwapSTETH.get_dy(WETHID, STETHID, amount);
        if (out < amount) {
            stETH.submit{value: amount}(REFERRAL);
        } else {
            StableSwapSTETH.exchange{value: amount}(
                WETHID,
                STETHID,
                amount,
                Math.max(amountOutMin, amount)
            );
        }

        return
            IwstETH(address(collateralToken)).wrap(
                stETH.balanceOf(address(this))
            );
    }

    function _convertCollateralToAsset(
        uint256 amount,
        uint256 amountOutMin
    ) internal override returns (uint256) {
        if (amount == 0) return 0;

        uint256 stETHAmount = IwstETH(address(collateralToken)).unwrap(amount);
        uint256 amountOut = StableSwapSTETH.exchange(
            STETHID,
            WETHID,
            stETHAmount,
            amountOutMin
        );
        IWETH(address(asset)).deposit{value: address(this).balance}();
        return amountOut;
    }

    function estimatedTotalAssets()
        public
        view
        override
        returns (uint256)
    {
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

    /// @notice Initiate stETH withdrawal through Lido queue for 1:1 redemption
    /// @param _amount Amount of LST to queue for withdrawal
    /// @return nftId Withdrawal ID number from the withdrawal request
    function initiateLSTWithdrawal(
        uint256 _amount
    ) external onlyEmergencyAuthorized returns (uint256 nftId) {
        _amount = Math.min(_amount, balanceOfCollateralToken());
        uint256 stETHAmount = IwstETH(address(collateralToken)).unwrap(_amount);

        require(
            stETHAmount > WITHDRAWAL_QUEUE.MIN_STETH_WITHDRAWAL_AMOUNT(),
            "!minimum"
        ); // minimum amount to withdraw
        require(
            stETHAmount <= WITHDRAWAL_QUEUE.MAX_STETH_WITHDRAWAL_AMOUNT(),
            "!maximum"
        ); // maximum amount to withdraw in one request

        pendingRedemptions += stETHAmount;

        return _initiateLSTWithdrawal(stETHAmount)[0];
    }

    /// @notice Initiate stETH withdrawal through Lido queue for 1:1 redemption
    /// @param _amount Amount of LST to queue for withdrawal
    /// @return requestIds Array of NFT IDs we created via our withdrawal
    function _initiateLSTWithdrawal(
        uint256 _amount
    ) internal returns (uint256[] memory requestIds) {
        stETH.forceApprove(address(WITHDRAWAL_QUEUE), _amount);

        uint256[] memory _amounts = new uint256[](1);
        _amounts[0] = _amount;

        requestIds = WITHDRAWAL_QUEUE.requestWithdrawals(
            _amounts,
            address(this)
        );
    }

    /// @notice Claim ETH from completed Lido withdrawal request
    /// @param _claimId The claim ID from the withdrawal request
    /// @return _redeemedAmount Amount of LST redeemed
    function claimLSTWithdrawal(
        uint256 _claimId
    ) external onlyEmergencyAuthorized returns (uint256 _redeemedAmount) {
        _redeemedAmount = _claimLSTWithdrawal(_claimId);
        pendingRedemptions = _redeemedAmount >= pendingRedemptions
            ? 0
            : pendingRedemptions - _redeemedAmount;
    }

    /// @notice Claim ETH from completed Lido withdrawal request
    /// @param _claimId The claim ID from the withdrawal request
    function _claimLSTWithdrawal(
        uint256 _claimId
    ) internal returns (uint256 _redeemedAmount) {
        uint256 preBalance = address(this).balance;
        WITHDRAWAL_QUEUE.claimWithdrawal(_claimId);
        _redeemedAmount = address(this).balance - preBalance;

        // Convert received ETH to WETH
        IWETH(address(asset)).deposit{value: address(this).balance}();
    }

    /// @notice Manually zero the pending redemptions in case of significant dust or a Lido slashing event.
    /// @dev Only may be called by governance.
    function zeroPendingRedemptions() external onlyEmergencyAuthorized {
        pendingRedemptions = 0;
    }
}
