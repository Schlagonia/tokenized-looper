// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {FluidSwapper} from "@periphery/swappers/FluidSwapper.sol";

import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title sUSDeExchange
 * @notice Strategy-bound exchange for ERC4626 collateral markets using Fluid.
 *         - `mint = true`: asset -> collateral swaps to the ERC4626 underlying, then deposits
 *         - `mint = false`: asset -> collateral falls back to market buying the share token
 *         - collateral -> asset always uses Fluid market liquidity
 * @dev Uses the configured `base` token as the bridge for Fluid's one or two hop routes.
 */
contract sUSDeExchange is FluidSwapper, BaseExchange {
    using SafeERC20 for ERC20;

    /// @notice Borrow token in the strategy (loan token).
    address public immutable ASSET;

    /// @notice ERC4626 collateral share token.
    address public immutable COLLATERAL;

    /// @notice ERC4626 underlying asset used by the mint path.
    address public immutable UNDERLYING;

    /// @notice Direct mint toggle for ASSET -> COLLATERAL exchanges.
    bool public mint;

    constructor(
        address _weth,
        address _base,
        address _asset,
        address _collateral
    ) FluidSwapper(_weth) {
        require(_base != address(0), "!base");
        require(_asset != address(0), "!asset");
        require(_collateral != address(0), "!collateral");

        ASSET = _asset;
        COLLATERAL = _collateral;
        UNDERLYING = IERC4626(_collateral).asset();
        require(UNDERLYING != address(0), "!underlying");

        base = _base;
        ERC20(UNDERLYING).forceApprove(_collateral, type(uint256).max);
    }

    function setMint(bool _mint) external onlyManagement {
        mint = _mint;
    }

    function setBase(address _base) external onlyManagement {
        require(_base != address(0), "!base");
        base = _base;
    }

    function setFluidDex(
        address _token0,
        address _token1,
        address _dex
    ) external onlyManagement {
        _setFluidDex(_token0, _token1, _dex);
    }

    function setFluidDex(
        address _from,
        address _to,
        address _dex,
        bool _swap0to1
    ) external onlyManagement {
        _setFluidDex(_from, _to, _dex, _swap0to1);
    }

    function setMinAmountToSell(
        uint256 _minAmountToSell
    ) external onlyManagement {
        _setMinAmountToSell(_minAmountToSell);
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal override(BaseExchange) returns (uint256 amountOut) {
        if (mint && from == ASSET && to == COLLATERAL) {
            uint256 underlyingAmount = from == UNDERLYING
                ? amountIn
                : _fluidSwapFrom(from, UNDERLYING, amountIn, 0);

            return
                IERC4626(COLLATERAL).deposit(underlyingAmount, address(this));
        }

        return _fluidSwapFrom(from, to, amountIn, amountOutMin);
    }
}
