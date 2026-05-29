// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MorphoLooper} from "./MorphoLooper.sol";
import {Id} from "../interfaces/morpho/IMorpho.sol";
import {IExchange} from "../interfaces/IExchange.sol";
import {ISyrupPool} from "../interfaces/syrup/ISyrupPool.sol";

/**
 * @title SyrupMorphoLooper
 * @notice Generic Morpho looper for syrup collateral markets where:
 *         - loanToken = underlying stablecoin (e.g. USDC/USDT)
 *         - collateralToken = matching syrup vault token (e.g. syrupUSDC/syrupUSDT)
 *         Primary conversion path delegates to an external exchange contract.
 */
contract SyrupMorphoLooper is MorphoLooper {
    using SafeERC20 for ERC20;

    address internal immutable UNDERLYING;

    /// @notice Shares queued for direct (async) redemption.
    uint256 public pendingRedemptionShares;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId,
        address _exchange,
        address _governance
    )
        MorphoLooper(
            _asset,
            _name,
            _collateralToken,
            _morpho,
            _marketId,
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
        // Don't allow reports since we cannot guarantee the pending redemption shares are filled or not
        require(pendingRedemptionShares == 0, "pending redemptions");
        return super._harvestAndReport();
    }

    function balanceOfUnderlying() public view returns (uint256) {
        return ERC20(UNDERLYING).balanceOf(address(this));
    }

    function protectedTokens()
        public
        view
        override
        returns (address[] memory _protected)
    {
        _protected = new address[](3);
        _protected[0] = address(asset);
        _protected[1] = collateralToken;
        _protected[2] = UNDERLYING;
    }

    /*//////////////////////////////////////////////////////////////
                        DIRECT REDEMPTION PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Queue syrup shares for direct redemption.
    /// @dev asset is directly sent back to the strategy once filled
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

    /// @notice Cancel queued redemption shares.
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

    /// @notice Manually clear pending redemptions.
    /// NOTE: Maple will automatically send usdc to the strategy. So this will
    ///       need to be called once done to allow reports to continue.
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
}
