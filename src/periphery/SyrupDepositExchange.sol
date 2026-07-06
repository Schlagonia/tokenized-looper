// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Governance} from "@periphery/utils/Governance.sol";

import {ISyrupRouter} from "../interfaces/syrup/ISyrupRouter.sol";

/**
 * @title SyrupDepositExchange
 * @notice Venue-specific Maple/Syrup deposit exchange for MetaExchange routes.
 */
contract SyrupDepositExchange is Governance, ReentrancyGuard {
    using SafeERC20 for ERC20;

    struct SyrupDepositConfig {
        address router;
        bytes32 depositData;
    }

    struct SyrupAuthorization {
        uint256 bitmap;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    mapping(address => SyrupDepositConfig) public syrupDepositConfigs;
    mapping(address => bool) public allowed;
    mapping(address => bool) public allowedForwarders;

    event AllowedSet(address indexed account, bool allowed);
    event AllowedForwarderSet(address indexed forwarder, bool allowed);
    event BalanceSwept(
        address indexed token,
        address indexed receiver,
        uint256 amount
    );
    event SyrupDepositConfigSet(
        address indexed vault,
        address indexed router,
        bytes32 depositData
    );
    event SyrupAuthorizedAndDeposited(
        address indexed vault,
        address indexed router,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address _governance) Governance(_governance) {}

    function name() external pure returns (string memory) {
        return "SyrupDepositExchange";
    }

    function setAllowed(
        address account,
        bool isAllowed
    ) external onlyGovernance {
        require(account != address(0), "!account");
        allowed[account] = isAllowed;
        emit AllowedSet(account, isAllowed);
    }

    function setAllowedForwarder(
        address forwarder,
        bool isAllowed
    ) external onlyGovernance {
        require(forwarder != address(0), "!forwarder");
        allowedForwarders[forwarder] = isAllowed;
        emit AllowedForwarderSet(forwarder, isAllowed);
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

    function sweep(address token, uint256 amount) external onlyGovernance {
        require(token != address(0), "!token");

        uint256 amountToSweep = amount == type(uint256).max
            ? ERC20(token).balanceOf(address(this))
            : amount;

        ERC20(token).safeTransfer(msg.sender, amountToSweep);
        emit BalanceSwept(token, msg.sender, amountToSweep);
    }

    function authorizeAndDeposit(
        address vault,
        uint256 amountIn,
        uint256 amountOutMin,
        SyrupAuthorization calldata auth
    ) external onlyGovernance nonReentrant returns (uint256 amountOut) {
        require(amountIn != 0, "!amountIn");

        SyrupDepositConfig memory config = syrupDepositConfigs[vault];
        require(config.router != address(0), "!syrup");

        address from = IERC4626(vault).asset();
        require(ERC20(from).balanceOf(address(this)) >= amountIn, "!balance");

        ERC20(from).forceApprove(config.router, amountIn);
        amountOut = ISyrupRouter(config.router).authorizeAndDeposit(
            auth.bitmap,
            auth.deadline,
            auth.v,
            auth.r,
            auth.s,
            amountIn,
            config.depositData
        );
        require(amountOut >= amountOutMin, "!amountOut");

        emit SyrupAuthorizedAndDeposited(
            vault,
            config.router,
            amountIn,
            amountOut
        );
    }

    function exchangeWithContext(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        address context
    ) external nonReentrant returns (uint256 amountOut) {
        require(allowedForwarders[msg.sender], "!forwarder");
        require(allowed[context], "!allowed");

        if (amountIn == 0) return 0;

        ERC20(from).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = _deposit(from, to, amountIn);
        require(amountOut >= amountOutMin, "!amountOut");
        ERC20(to).safeTransfer(msg.sender, amountOut);
    }

    function _deposit(
        address from,
        address vault,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        require(IERC4626(vault).asset() == from, "!vaultAsset");

        SyrupDepositConfig memory config = syrupDepositConfigs[vault];
        require(config.router != address(0), "!syrup");

        ERC20(from).forceApprove(config.router, amountIn);
        return
            ISyrupRouter(config.router).deposit(amountIn, config.depositData);
    }
}
