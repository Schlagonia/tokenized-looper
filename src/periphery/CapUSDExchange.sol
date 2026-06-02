// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICapToken} from "../interfaces/cap/ICapToken.sol";
import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title CapUSDExchange
 * @notice Venue-specific Cap token mint/burn exchange for MetaExchange routes.
 */
contract CapUSDExchange is BaseExchange {
    using SafeERC20 for ERC20;

    address public immutable asset;
    address public immutable capToken;

    constructor(
        address _asset,
        address _capToken,
        address _governance
    ) BaseExchange(_governance) {
        require(_asset != address(0) && _capToken != address(0), "!cap");
        asset = _asset;
        capToken = _capToken;
    }

    function name() external pure override returns (string memory) {
        return "CapUSDExchange";
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256
    ) internal override returns (uint256 amountOut) {
        if (from == asset && to == capToken) {
            ERC20(from).forceApprove(capToken, amountIn);
            return
                ICapToken(capToken).mint(
                    asset,
                    amountIn,
                    0,
                    address(this),
                    block.timestamp
                );
        }

        require(from == capToken && to == asset, "!cap");
        ERC20(from).forceApprove(capToken, amountIn);
        amountOut = ICapToken(capToken).burn(
            asset,
            amountIn,
            0,
            address(this),
            block.timestamp
        );
    }
}
