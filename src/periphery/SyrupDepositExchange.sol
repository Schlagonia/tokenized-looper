// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISyrupRouter} from "../interfaces/syrup/ISyrupRouter.sol";
import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title SyrupDepositExchange
 * @notice Venue-specific Maple/Syrup deposit exchange for MetaExchange routes.
 */
contract SyrupDepositExchange is BaseExchange {
    using SafeERC20 for ERC20;

    struct SyrupDepositConfig {
        address router;
        bytes32 depositData;
    }

    mapping(address => SyrupDepositConfig) public syrupDepositConfigs;

    event SyrupDepositConfigSet(
        address indexed vault,
        address indexed router,
        bytes32 depositData
    );

    function name() external pure override returns (string memory) {
        return "SyrupDepositExchange";
    }

    function setSyrupDepositConfig(
        address vault,
        address router,
        bytes32 depositData
    ) external onlyGovernance {
        require(vault != address(0) && router != address(0), "!syrup");
        syrupDepositConfigs[vault] = SyrupDepositConfig({
            router: router,
            depositData: depositData
        });
        emit SyrupDepositConfigSet(vault, router, depositData);
    }

    function _exchange(
        address from,
        address vault,
        uint256 amountIn,
        uint256
    ) internal override returns (uint256 amountOut) {
        require(IERC4626(vault).asset() == from, "!vaultAsset");

        SyrupDepositConfig memory config = syrupDepositConfigs[vault];
        require(config.router != address(0), "!syrup");

        ERC20(from).forceApprove(config.router, amountIn);
        return
            ISyrupRouter(config.router).deposit(amountIn, config.depositData);
    }
}
