// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {CurveSwapper} from "@periphery/swappers/CurveSwapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title CurveExchange
 * @notice Venue-specific Curve exchange for MetaExchange routes.
 */
contract CurveExchange is CurveSwapper, BaseExchange {
    using SafeERC20 for ERC20;

    constructor(address _curveRouter) {
        require(_curveRouter != address(0), "!router");
        curveRouter = _curveRouter;
    }

    function name() external pure override returns (string memory) {
        return "CurveExchange";
    }

    function setCurveRoute(
        address from,
        address to,
        address[11] memory route,
        uint256[5][5] memory swapParams,
        address[5] memory pools
    ) external onlyOperator {
        _setCurveRoute(from, to, route, swapParams, pools);
    }

    function getCurveRoute(
        address from,
        address to
    )
        external
        view
        returns (
            address[11] memory route,
            uint256[5][5] memory swapParams,
            address[5] memory pools
        )
    {
        CurveRouteParams storage params = _curveRoutes[from][to];
        return (params.route, params.swapParams, params.pools);
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal override returns (uint256 amountOut) {
        return _curveSwapFrom(from, to, amountIn, amountOutMin);
    }

    function _checkAllowance(
        address spender,
        address token,
        uint256 amount
    ) internal override {
        if (ERC20(token).allowance(address(this), spender) < amount) {
            ERC20(token).forceApprove(spender, type(uint256).max);
        }
    }
}
