// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFluidDexT1} from "@periphery/interfaces/Fluid/IFluidDexV2Router.sol";
import {BaseSwapper} from "@periphery/swappers/BaseSwapper.sol";

interface IMetaFluidWETH {
    function deposit() external payable;

    function withdraw(uint256) external;
}

/**
 * @title MetaFluidSwapper
 * @notice Local Fluid swapper mixin for MetaExchange. Same job, fewer naming collisions.
 */
contract MetaFluidSwapper is BaseSwapper {
    using SafeERC20 for ERC20;

    address internal constant NATIVE_ETH =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public immutable WETH;
    address public fluidBase;

    struct FluidDexConfig {
        address dex;
        bool swap0to1;
    }

    mapping(address => mapping(address => FluidDexConfig)) public fluidDexes;

    constructor(address _weth) {
        WETH = _weth;
        fluidBase = _weth;
    }

    function _setFluidDex(
        address _token0,
        address _token1,
        address _dex
    ) internal virtual {
        IFluidDexT1.ConstantViews memory _constants = IFluidDexT1(_dex)
            .constantsView();

        if (_constants.token0 == NATIVE_ETH) _constants.token0 = WETH;
        if (_constants.token1 == NATIVE_ETH) _constants.token1 = WETH;

        if (_constants.token0 == _token0 && _constants.token1 == _token1) {
            _setFluidDex(_token0, _token1, _dex, true);
        } else if (
            _constants.token0 == _token1 && _constants.token1 == _token0
        ) {
            _setFluidDex(_token0, _token1, _dex, false);
        } else {
            revert("dex mismatch");
        }
    }

    function _setFluidDex(
        address _from,
        address _to,
        address _dex,
        bool _swap0to1
    ) internal virtual {
        require(
            _from != address(0) && _to != address(0) && _dex != address(0),
            "bad token"
        );
        require(_from != _to, "same token");

        fluidDexes[_from][_to] = FluidDexConfig({
            dex: _dex,
            swap0to1: _swap0to1
        });
        fluidDexes[_to][_from] = FluidDexConfig({
            dex: _dex,
            swap0to1: !_swap0to1
        });
    }

    function _fluidSwapFrom(
        address _from,
        address _to,
        uint256 _amountIn,
        uint256 _minAmountOut
    ) internal virtual returns (uint256 _amountOut) {
        if (_amountIn != 0 && _amountIn >= minAmountToSell) {
            if (_from == WETH) {
                IMetaFluidWETH(WETH).withdraw(_amountIn);
            }

            if (_from == fluidBase || _to == fluidBase) {
                _amountOut = _fluidSwapInStep(
                    _from,
                    _to,
                    _amountIn,
                    _minAmountOut
                );
            } else {
                _amountOut = _fluidSwapInStep(_from, fluidBase, _amountIn, 0);
                _amountOut = _fluidSwapInStep(
                    fluidBase,
                    _to,
                    _amountOut,
                    _minAmountOut
                );
            }

            if (_to == WETH) {
                uint256 _ethBalance = address(this).balance;
                if (_ethBalance > 0) {
                    IMetaFluidWETH(WETH).deposit{value: _ethBalance}();
                }
            }
        }
    }

    function _fluidSwapInStep(
        address _from,
        address _to,
        uint256 _amountIn,
        uint256 _minAmountOut
    ) internal virtual returns (uint256 _amountOut) {
        FluidDexConfig memory _config = fluidDexes[_from][_to];
        require(_config.dex != address(0), "dex not set");

        uint256 _msgValue;

        if (_from == WETH) {
            _msgValue = _amountIn;
        } else {
            ERC20(_from).forceApprove(_config.dex, _amountIn);
        }

        _amountOut = IFluidDexT1(_config.dex).swapIn{value: _msgValue}(
            _config.swap0to1,
            _amountIn,
            _minAmountOut,
            address(this)
        );
    }
}
