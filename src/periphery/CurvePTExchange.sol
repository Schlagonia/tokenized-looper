// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CurveSwapper} from "@periphery/swappers/CurveSwapper.sol";
import {PendleSwapper} from "@periphery/swappers/PendleSwapper.sol";

import {PTExchange} from "./PTExchange.sol";

/**
 * @title CurvePTExchange
 * @notice Strategy-bound PT exchange that routes asset <-> Pendle token through Curve.
 */
contract CurvePTExchange is CurveSwapper, PTExchange {
    using SafeERC20 for ERC20;

    constructor(
        address _asset,
        address _collateral,
        address _pendleMarket,
        address _pendleToken
    ) PTExchange(_asset, _collateral, _pendleMarket, _pendleToken) {}

    function setCurveRouter(address _curveRouter) external onlyManagement {
        require(_curveRouter != address(0), "!router");
        curveRouter = _curveRouter;
    }

    function setCurveRoute(
        address _from,
        address _to,
        address[11] memory _route,
        uint256[5][5] memory _swapParams,
        address[5] memory _pools
    ) external onlyManagement {
        _setCurveRoute(_from, _to, _route, _swapParams, _pools);
    }

    function _convertAssetToPendleToken(
        uint256 amount
    ) internal virtual override returns (uint256) {
        return _curveSwapFrom(ASSET, PENDLE_TOKEN, amount, 0);
    }

    function _convertPendleTokenToAsset(
        uint256 amount
    ) internal virtual override returns (uint256) {
        return _curveSwapFrom(PENDLE_TOKEN, ASSET, amount, 0);
    }

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal virtual override(CurveSwapper, PendleSwapper) {
        if (ERC20(_token).allowance(address(this), _contract) < _amount) {
            ERC20(_token).forceApprove(_contract, _amount);
        }
    }
}
