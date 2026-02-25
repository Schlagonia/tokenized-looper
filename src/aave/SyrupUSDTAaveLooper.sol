// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseAaveLooper} from "./BaseAaveLooper.sol";
import {ISyrupPool} from "../interfaces/syrup/ISyrupPool.sol";
import {UniswapUniversalSwapper} from "@periphery/swappers/UniswapUniversalSwapper.sol";

/**
 * @title SyrupUSDTAaveLooper
 * @notice Aave V3 looper for syrupUSDT collateral and USDT debt.
 *         - Default path uses Uniswap Universal Router (V3/V4 capable) swaps.
 *         - Emergency path supports direct syrup redemption requests.
 */
contract SyrupUSDTAaveLooper is BaseAaveLooper, UniswapUniversalSwapper {
    /// @notice Shares queued for direct syrup redemption.
    uint256 public pendingRedemptionShares;

    constructor(
        address _asset, // USDT
        string memory _name,
        address _collateralToken, // syrupUSDT
        address _addressesProvider,
        address _morpho,
        uint8 _eModeCategoryId,
        address _weth,
        bytes32 _assetCollateralV4PoolId
    )
        BaseAaveLooper(
            _asset,
            _name,
            _collateralToken,
            _addressesProvider,
            _morpho,
            _eModeCategoryId
        )
        UniswapUniversalSwapper(_weth)
    {
        // Keep swaps single-hop for the strategy pair.
        base = _asset;
        _setV4Pool(_asset, _collateralToken, _assetCollateralV4PoolId);
    }

    function setUniFees(
        address _token0,
        address _token1,
        uint24 _fee
    ) external onlyManagement {
        _setUniFees(_token0, _token1, _fee);
    }

    function setV4Pool(
        address _token0,
        address _token1,
        bytes32 _poolId
    ) external onlyManagement {
        _setV4Pool(_token0, _token1, _poolId);
    }

    function setBase(address _base) external onlyManagement {
        base = _base;
    }

    function setMinAmountToSell(
        uint256 _minAmountToSell
    ) external onlyManagement {
        _setMinAmountToSell(_minAmountToSell);
    }

    /*//////////////////////////////////////////////////////////////
                            CONVERSIONS
    //////////////////////////////////////////////////////////////*/

    function _convertAssetToCollateral(
        uint256 amount,
        uint256 amountOutMin
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        return _swapFrom(address(asset), collateralToken, amount, amountOutMin);
    }

    function _convertCollateralToAsset(
        uint256 amount,
        uint256 amountOutMin
    ) internal override returns (uint256) {
        if (amount == 0) return 0;
        return _swapFrom(collateralToken, address(asset), amount, amountOutMin);
    }

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
        require(pendingRedemptionShares == 0, "pending redemptions");
        return super._harvestAndReport();
    }

    /*//////////////////////////////////////////////////////////////
                        DIRECT REDEMPTION PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Queue syrup shares for direct redemption (non-swap path).
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

    /// @notice Cancel queued direct redemptions and restore shares to wallet.
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

    /// @notice Claim available direct redemptions into USDT.
    function claimDirectRedemption(
        uint256 _shares
    ) external onlyEmergencyAuthorized returns (uint256 _amountOut) {
        if (_shares == type(uint256).max) {
            _shares = ISyrupPool(collateralToken).maxRedeem(address(this));
        }
        require(_shares > 0, "!shares");

        _amountOut = ISyrupPool(collateralToken).redeem(
            _shares,
            address(this),
            address(this)
        );

        pendingRedemptionShares = _shares >= pendingRedemptionShares
            ? 0
            : pendingRedemptionShares - _shares;
    }

    /// @notice Manually zero pending redemptions in exceptional scenarios.
    function zeroPendingRedemptions() external onlyEmergencyAuthorized {
        pendingRedemptionShares = 0;
    }

    /*//////////////////////////////////////////////////////////////
                        NO-OP REWARDS (NONE)
    //////////////////////////////////////////////////////////////*/

    function _claimAndSellRewards() internal pure override {}
}
