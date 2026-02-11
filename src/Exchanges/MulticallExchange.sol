// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseExchange} from "./BaseExchange.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

contract MulticallExchange is BaseExchange {
    using Address for address;

    struct Call {
        address target;
        uint256 value;
        bytes callData;
    }

    function _exchange(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata data) internal override returns (uint256 amountOut) {

        Call[] memory calls = abi.decode(data, (Call[]));
        Call memory call;
        for (uint256 i = 0; i < calls.length; i++) {
            call = calls[i];
            call.target.functionCallWithValue(call.callData, call.value);
        }
    }
}