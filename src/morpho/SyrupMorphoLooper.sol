// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseMorphoLooper} from "./BaseMorphoLooper.sol";
import {Id} from "../interfaces/morpho/IMorpho.sol";
import {ISyrupPool} from "../interfaces/syrup/ISyrupPool.sol";
import {UniswapUniversalSwapper} from "@periphery/swappers/UniswapUniversalSwapper.sol";

/**
 * @title SyrupMorphoLooper
 * @notice Generic Morpho looper for syrup collateral markets where:
 *         - loanToken = underlying stablecoin (e.g. USDC/USDT)
 *         - collateralToken = matching syrup vault token (e.g. syrupUSDC/syrupUSDT)
 *         Primary conversion path uses Universal Swapper routes.
 */
contract SyrupMorphoLooper is BaseMorphoLooper, UniswapUniversalSwapper {
    using SafeERC20 for ERC20;

    /// @notice Shares queued for direct (async) redemption.
    uint256 public pendingRedemptionShares;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId,
        address _weth,
        bytes32 _assetCollateralV4PoolId
    )
        BaseMorphoLooper(_asset, _name, _collateralToken, _morpho, _marketId)
        UniswapUniversalSwapper(_weth)
    {
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

    function setV4Pool(
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing,
        address _hooks
    ) external onlyManagement {
        _setV4Pool(_token0, _token1, _fee, _tickSpacing, _hooks);
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

    /// @notice Queue syrup shares for direct redemption.
    /// @dev asset is directly sent back to the strategy once filled
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

    /// @notice Cancel queued redemption shares.
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

    /// @notice Manually clear pending redemptions in exceptional scenarios.
    function zeroPendingRedemptions() external onlyEmergencyAuthorized {
        pendingRedemptionShares = 0;
    }

    /*//////////////////////////////////////////////////////////////
                        NO-OP REWARDS (NONE)
    //////////////////////////////////////////////////////////////*/

    function _claimAndSellRewards() internal pure override {}
}
