// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MorphoLooper} from "./MorphoLooper.sol";
import {IExchange} from "../interfaces/IExchange.sol";
import {Id} from "../interfaces/morpho/IMorpho.sol";
import {IOUSD} from "../interfaces/origin/IOUSD.sol";
import {IOUSDVault} from "../interfaces/origin/IOUSDVault.sol";

/**
 * @title OriginMorphoLooper
 * @notice Morpho looper for wrapped Origin collateral (e.g. wOUSD) with async vault withdrawals.
 */
contract OriginMorphoLooper is MorphoLooper {
    using SafeERC20 for ERC20;

    address public immutable UNDERLYING;
    IOUSDVault public immutable VAULT;
    uint256 public pendingWithdrawalAssets;

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
        UNDERLYING = IERC4626(_collateralToken).asset();
        VAULT = IOUSDVault(IOUSD(UNDERLYING).vaultAddress());

        require(VAULT.asset() == _asset, "!vault asset");

        ERC20(UNDERLYING).forceApprove(address(VAULT), type(uint256).max);
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return
            super.estimatedTotalAssets() +
            _assetToCollateral(balanceOfUnderlying() + pendingWithdrawalAssets);
    }

    function balanceOfUnderlying() public view returns (uint256) {
        return ERC20(UNDERLYING).balanceOf(address(this));
    }

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        require(pendingWithdrawalAssets == 0, "pending withdrawals");
        return super._harvestAndReport();
    }

    function initiateWithdrawal(
        uint256 _shares
    )
        external
        onlyEmergencyAuthorized
        returns (uint256 requestId, uint256 assets)
    {
        require(pendingWithdrawalAssets == 0, "pending withdrawals");

        _shares = Math.min(_shares, balanceOfCollateralToken());
        require(_shares > 0, "!shares");

        uint256 underlyingAmount = IERC4626(collateralToken).redeem(
            _shares,
            address(this),
            address(this)
        );

        (requestId, ) = VAULT.requestWithdrawal(underlyingAmount);

        pendingWithdrawalAssets = underlyingAmount;
    }

    function claimWithdrawal(
        uint256 requestId
    ) external onlyEmergencyAuthorized returns (uint256 assets) {
        assets = VAULT.claimWithdrawal(requestId);
        pendingWithdrawalAssets = assets < pendingWithdrawalAssets
            ? pendingWithdrawalAssets - assets
            : 0;
    }

    function zeroPendingWithdrawals() external onlyEmergencyAuthorized {
        pendingWithdrawalAssets = 0;
    }
}
