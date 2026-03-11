// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {UniswapUniversalSwapper} from "@periphery/swappers/UniswapUniversalSwapper.sol";

import {BaseExchange} from "./BaseExchange.sol";
import {ISyrupRouter} from "../interfaces/syrup/ISyrupRouter.sol";

/**
 * @title SyrupExchange
 * @notice Strategy-bound exchange for syrup collateral markets.
 *         - `mint = true`: asset -> collateral uses Maple Syrup Router deposit
 *         - `mint = false`: falls back to Universal Router swap path
 *         - collateral -> asset always uses Universal Router swap path
 */
contract SyrupExchange is UniswapUniversalSwapper, BaseExchange {
    using SafeERC20 for ERC20;

    /// @notice Borrow token in the strategy (loan token).
    address public immutable ASSET;

    /// @notice Syrup collateral token (ERC4626 share token).
    address public immutable COLLATERAL;

    /// @notice Maple Syrup router used by mint path.
    address public immutable SYRUP_ROUTER;

    /// @notice Direct mint toggle for ASSET -> COLLATERAL exchanges.
    bool public mint;

    bytes32 public depositData;

    constructor(
        address _weth,
        address _asset,
        address _collateral,
        address _syrupRouter
    ) UniswapUniversalSwapper(_weth) {
        require(_asset != address(0), "!asset");
        require(_collateral != address(0), "!collateral");
        require(_syrupRouter != address(0), "!router");
        require(IERC4626(_collateral).asset() == _asset, "!asset");

        ASSET = _asset;
        COLLATERAL = _collateral;
        SYRUP_ROUTER = _syrupRouter;
        depositData = bytes32("Yearn");
        ERC20(ASSET).forceApprove(_syrupRouter, type(uint256).max);
    }

    function setMint(bool _mint) external onlyManagement {
        mint = _mint;
    }

    function setDepositData(bytes32 _depositData) external onlyManagement {
        depositData = _depositData;
    }

    function authorizeAndDeposit(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyManagement returns (uint256 amountOut) {
        amountOut = ISyrupRouter(SYRUP_ROUTER).authorizeAndDeposit(
            amount,
            depositData,
            deadline,
            v,
            r,
            s
        );
    }

    function setUniFees(
        address _token0,
        address _token1,
        uint24 _fee
    ) external onlyManagement {
        _setUniFees(_token0, _token1, _fee);
    }

    function setV4Pool(
        address _token0,
        address _token1,
        bytes32 _poolId
    ) external onlyManagement {
        _setV4Pool(_token0, _token1, _poolId);
    }

    function setBase(address _base) external onlyManagement {
        require(_base != address(0), "!base");
        base = _base;
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal override(BaseExchange) returns (uint256 amountOut) {
        if (mint && from == ASSET && to == COLLATERAL) {
            return ISyrupRouter(SYRUP_ROUTER).deposit(amountIn, depositData);
        }

        return _swapFrom(from, to, amountIn, amountOutMin);
    }
}
