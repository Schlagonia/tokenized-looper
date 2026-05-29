// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AaveLooper} from "./AaveLooper.sol";
import {IExchange} from "../interfaces/IExchange.sol";
import {ISyrupPool} from "../interfaces/syrup/ISyrupPool.sol";

/**
 * @title SyrupUSDTAaveLooper
 * @notice Aave V3 looper for syrupUSDT collateral and USDT debt.
 *         - Default path delegates swaps to a dedicated exchange contract.
 *         - Management path supports direct syrup redemption requests.
 */
contract SyrupUSDTAaveLooper is AaveLooper {
    using SafeERC20 for ERC20;

    address internal immutable UNDERLYING;

    /// @notice Shares queued for direct syrup redemption.
    uint256 public pendingRedemptionShares;

    constructor(
        address _asset, // USDT
        string memory _name,
        address _collateralToken, // syrupUSDT
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
    {
        UNDERLYING = ISyrupPool(_collateralToken).asset();
    }

    function totalCollateralBalance() public view override returns (uint256) {
        uint256 looseUnderlyingShares;
        if (UNDERLYING != address(asset)) {
            looseUnderlyingShares = ISyrupPool(collateralToken).convertToShares(
                balanceOfUnderlying()
            );
        }

        return
            super.totalCollateralBalance() +
            pendingRedemptionShares +
            looseUnderlyingShares;
    }

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        require(pendingRedemptionShares == 0, "pending redemptions");
        return super._harvestAndReport();
    }

    function balanceOfUnderlying() public view returns (uint256) {
        return ERC20(UNDERLYING).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        DIRECT REDEMPTION PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Queue syrup shares for direct redemption (non-swap path).
    function initiateDirectRedemption(
        uint256 _shares
    ) external onlyManagement returns (uint256 _exitShares) {
        _shares = Math.min(_shares, balanceOfCollateralToken());
        require(_shares > 0, "!shares");

        _exitShares = ISyrupPool(collateralToken).requestRedeem(
            _shares,
            address(this)
        );
        pendingRedemptionShares += _exitShares;
    }

    /// @notice Cancel queued direct redemptions and restore shares to wallet.
    function cancelDirectRedemption(
        uint256 _shares
    ) external onlyManagement returns (uint256 _removedShares) {
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

    /// @notice Manually zero pending redemptions in exceptional scenarios.
    function zeroPendingRedemptions() external onlyManagement {
        pendingRedemptionShares = 0;
    }

    function convertUnderlyingToAsset(
        uint256 amount
    ) external onlyKeepers returns (uint256) {
        require(UNDERLYING != address(asset), "!underlying");
        amount = Math.min(amount, balanceOfUnderlying());
        if (amount == 0) return 0;

        uint256 expectedAmountOut = _collateralToAsset(
            ISyrupPool(collateralToken).convertToShares(amount)
        );
        _updateSlippageLossLimit();

        ERC20(UNDERLYING).forceApprove(exchange, amount);
        uint256 amountOut = IExchange(exchange).exchange(
            UNDERLYING,
            address(asset),
            amount,
            0
        );

        _recordSlippage(expectedAmountOut, amountOut);
        return amountOut;
    }

    function _claimAndSellRewards() internal pure override {}
}
