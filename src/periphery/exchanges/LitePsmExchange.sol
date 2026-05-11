// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILitePSMWrapper} from "../../interfaces/sky/ILitePSMWrapper.sol";
import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title LitePsmExchange
 * @notice Venue-specific Sky LitePSM exchange for MetaExchange routes.
 */
contract LitePsmExchange is BaseExchange {
    using SafeERC20 for ERC20;

    address public immutable gem;
    address public immutable usds;
    address public immutable wrapper;
    uint256 public immutable scale;

    constructor(address _gem, address _usds, address _wrapper, uint256 _scale) {
        require(
            _gem != address(0) &&
                _usds != address(0) &&
                _wrapper != address(0) &&
                _scale != 0,
            "!psm"
        );
        gem = _gem;
        usds = _usds;
        wrapper = _wrapper;
        scale = _scale;
    }

    function name() external pure override returns (string memory) {
        return "LitePsmExchange";
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256
    ) internal override returns (uint256 amountOut) {
        if (from == gem && to == usds) {
            ERC20(from).forceApprove(wrapper, amountIn);
            return ILitePSMWrapper(wrapper).sellGem(address(this), amountIn);
        }

        require(from == usds && to == gem, "!psm");

        uint256 gemAmount = amountIn / scale;
        require(gemAmount != 0, "!amountOut");

        ERC20(from).forceApprove(wrapper, amountIn);

        uint256 balanceBefore = ERC20(to).balanceOf(address(this));
        ILitePSMWrapper(wrapper).buyGem(address(this), gemAmount);
        amountOut = ERC20(to).balanceOf(address(this)) - balanceBefore;
    }
}
