// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICurveNG} from "../interfaces/ICurveNG.sol";
import {PTExchange} from "./PTExchange.sol";

/**
 * @title sUSDaiPTExchange
 * @notice PT exchange variant that routes ASSET <-> PENDLE_TOKEN via Curve NG.
 *         Intended for USDC <-> sUSDai before/after Pendle PT swaps.
 */
contract sUSDaiPTExchange is PTExchange {
    using SafeERC20 for ERC20;

    ICurveNG public constant CURVE_POOL =
        ICurveNG(0xa7CF5543a27BaDC3a74d51EA0A02E84799140E4E);

    int128 public constant USDC_INDEX = 1;
    int128 public constant SUSDAI_INDEX = 0;

    constructor(
        address _asset,
        address _collateral,
        address _pendleMarket,
        address _pendleToken
    ) PTExchange(_asset, _collateral, _pendleMarket, _pendleToken) {
        ERC20(_asset).forceApprove(address(CURVE_POOL), type(uint256).max);
        ERC20(_pendleToken).forceApprove(
            address(CURVE_POOL),
            type(uint256).max
        );
    }

    function _convertAssetToPendleToken(
        uint256 amount
    ) internal override returns (uint256) {
        return CURVE_POOL.exchange(USDC_INDEX, SUSDAI_INDEX, amount, 0);
    }

    function _convertPendleTokenToAsset(
        uint256 amount
    ) internal override returns (uint256) {
        return CURVE_POOL.exchange(SUSDAI_INDEX, USDC_INDEX, amount, 0);
    }
}
