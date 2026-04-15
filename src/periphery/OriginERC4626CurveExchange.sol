// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IOUSD} from "../interfaces/origin/IOUSD.sol";
import {IOUSDVault} from "../interfaces/origin/IOUSDVault.sol";
import {ERC4626CurveExchange} from "./ERC4626CurveExchange.sol";

/**
 * @title OriginERC4626CurveExchange
 * @notice ERC4626 exchange for wrapped Origin collateral.
 *         - `mint = true`: ASSET -> UNDERLYING uses the Origin vault mint path
 *         - UNDERLYING -> ASSET uses Curve for immediate exits
 */
contract OriginERC4626CurveExchange is ERC4626CurveExchange {
    using SafeERC20 for ERC20;

    address public immutable VAULT;

    bool public mint = true;

    constructor(
        address _asset,
        address _collateral
    ) ERC4626CurveExchange(_asset, _collateral) {
        VAULT = IOUSD(UNDERLYING).vaultAddress();
        require(IOUSDVault(VAULT).asset() == ASSET, "!vault asset");

        ERC20(ASSET).forceApprove(VAULT, type(uint256).max);
    }

    function setMint(bool _mint) external onlyManagement {
        mint = _mint;
    }

    function _swapFrom(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal virtual override returns (uint256 amountOut) {
        if (mint && from == ASSET && to == UNDERLYING) {
            uint256 balanceBefore = ERC20(UNDERLYING).balanceOf(address(this));
            IOUSDVault(VAULT).mint(amountIn);
            amountOut =
                ERC20(UNDERLYING).balanceOf(address(this)) -
                balanceBefore;
            require(amountOut >= amountOutMin, "!amountOut");
            return amountOut;
        }

        return super._swapFrom(from, to, amountIn, amountOutMin);
    }
}
