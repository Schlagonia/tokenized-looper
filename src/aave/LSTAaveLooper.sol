// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AaveLooper} from "./AaveLooper.sol";
import {IQueue, IWETH, IwstETH} from "../interfaces/IStethInterfaces.sol";

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

    address internal constant STETH =
        0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH =
        0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WITHDRAWAL_QUEUE =
        0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

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
    function initiateCooldown(
        uint256 _amount
    ) external onlyManagement returns (uint256 nftId) {
        uint256 balance = ERC20(WSTETH).balanceOf(address(this));
        if (_amount > balance) _amount = balance;

        uint256 pendingAssets = IwstETH(WSTETH).unwrap(_amount);
        ERC20(STETH).forceApprove(WITHDRAWAL_QUEUE, pendingAssets);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = pendingAssets;

        nftId = IQueue(WITHDRAWAL_QUEUE).requestWithdrawals(
            amounts,
            address(this)
        )[0];

        unchecked {
            pendingRedemptions += pendingAssets;
        }
    }

    /// @notice Claim ETH from completed Lido withdrawal request
    /// @param _claimId The claim ID from the withdrawal request
    /// @return assets Amount of LST redeemed
    function claimCooldown(
        uint256 _claimId
    ) external payable onlyKeepers returns (uint256 assets) {
        uint256 preBalance = IWETH(WETH).balanceOf(address(this));
        IQueue(WITHDRAWAL_QUEUE).claimWithdrawal(_claimId);
        if (address(this).balance > 0) {
            IWETH(WETH).deposit{value: address(this).balance}();
        }
        assets = IWETH(WETH).balanceOf(address(this)) - preBalance;

        if (assets >= pendingRedemptions) {
            delete pendingRedemptions;
        } else {
            unchecked {
                pendingRedemptions -= assets;
            }
        }
    }

    /// @notice Manually zero pending redemptions in exceptional scenarios.
    function zeroPendingRedemptions() external payable onlyManagement {
        delete pendingRedemptions;
    }
}
