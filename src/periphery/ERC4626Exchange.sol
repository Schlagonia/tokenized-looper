// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title ERC4626Exchange
 * @notice Venue-specific ERC-4626 deposit/redeem exchange for MetaExchange routes.
 */
contract ERC4626Exchange is BaseExchange {
    using SafeERC20 for ERC20;

    constructor(address _governance) BaseExchange(_governance) {}

    function name() external pure override returns (string memory) {
        return "ERC4626Exchange";
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256
    ) internal override returns (uint256 amountOut) {
        try IERC4626(to).asset() returns (address asset) {
            if (asset == from) {
                ERC20(from).forceApprove(to, amountIn);
                return IERC4626(to).deposit(amountIn, address(this));
            }
        } catch {}

        try IERC4626(from).asset() returns (address asset) {
            require(asset == to, "!vaultAsset");
            return
                IERC4626(from).redeem(amountIn, address(this), address(this));
        } catch {
            revert("!vaultAsset");
        }
    }
}
