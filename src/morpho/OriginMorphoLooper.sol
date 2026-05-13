// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MorphoLooper} from "./MorphoLooper.sol";
import {Id} from "../interfaces/morpho/IMorpho.sol";
import {OriginWithdrawalLib} from "../libraries/OriginWithdrawalLib.sol";

/**
 * @title OriginMorphoLooper
 * @notice Morpho looper for wrapped Origin collateral (e.g. wOUSD) with async vault withdrawals.
 */
contract OriginMorphoLooper is MorphoLooper {
    address public constant UNDERLYING =
        0x2A8e1E676Ec238d8A992307B495b45B3fEAa5e86;

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
    {}

    function estimatedTotalAssets() public view override returns (uint256) {
        return
            super.estimatedTotalAssets() +
            _collateralToAsset(
                IERC4626(address(collateralToken)).convertToShares(
                    balanceOfUnderlying() + pendingWithdrawalAssets
                )
            );
    }

    function balanceOfUnderlying() public view returns (uint256) {
        return OriginWithdrawalLib.balanceOfUnderlying();
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
        returns (uint256 requestId, uint256 underlyingAmount)
    {
        require(pendingWithdrawalAssets == 0, "pending withdrawals");

        _shares = Math.min(_shares, balanceOfCollateralToken());
        require(_shares > 0, "!shares");

        (requestId, underlyingAmount) = OriginWithdrawalLib.initiate(_shares);

        pendingWithdrawalAssets = underlyingAmount;
    }

    function claimWithdrawal(
        uint256 requestId
    ) external onlyEmergencyAuthorized returns (uint256 assets) {
        assets = OriginWithdrawalLib.claim(requestId);
        pendingWithdrawalAssets = assets < pendingWithdrawalAssets
            ? pendingWithdrawalAssets - assets
            : 0;
    }

    function zeroPendingWithdrawals() external onlyEmergencyAuthorized {
        pendingWithdrawalAssets = 0;
    }
}
