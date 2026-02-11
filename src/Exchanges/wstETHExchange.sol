// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseExchange, ERC20, SafeERC20} from "./BaseExchange.sol";
import {ISteth, IWETH, ICurveFi, IwstETH} from "../interfaces/IStethInterfaces.sol";

contract wstETHExchange is BaseExchange {
    using SafeERC20 for *;

    ICurveFi public constant StableSwapSTETH =
        ICurveFi(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);

    ISteth public constant stETH =
        ISteth(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

    IWETH public constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    IwstETH public constant WSTETH = IwstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    address internal constant REFERRAL =
        0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;

    // stETH specific constants
    int128 internal constant WETHID = 0;
    int128 internal constant STETHID = 1;

    constructor() {
        stETH.forceApprove(address(StableSwapSTETH), type(uint256).max);
        stETH.forceApprove(address(WSTETH), type(uint256).max);
    }

    receive() external payable {}

    function _exchange(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata
    ) internal override returns (uint256 amountOut) {
        if (tokenIn == address(WETH)) {
            amountOut = _wethToWstETH(amountIn);
        } else if (tokenOut == address(WETH)) {
            amountOut = _wstETHToWeth(amountIn);
        }
    }

    function _wethToWstETH(uint256 amountIn) internal returns (uint256 amountOut) {
        WETH.withdraw(amountIn);

        //test if we should buy instead of mint
        uint256 out = StableSwapSTETH.get_dy(WETHID, STETHID, amountIn);
        if (out < amountIn) {
            stETH.submit{value: amountIn}(REFERRAL);
        } else {
            StableSwapSTETH.exchange{value: amountIn}(
                WETHID,
                STETHID,
                amountIn,
                amountIn
            );
        }

        return
            WSTETH.wrap(
                stETH.balanceOf(address(this))
            );
    }

    function _wstETHToWeth(uint256 amountIn) internal returns (uint256 amountOut) {
        uint256 stETHAmount = WSTETH.unwrap(amountIn);
        amountOut = StableSwapSTETH.exchange(
            STETHID,
            WETHID,
            stETHAmount,
            0
        );

        WETH.deposit{value: address(this).balance}();
    }
}