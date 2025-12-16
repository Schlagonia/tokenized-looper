// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IBaseLooper} from "./IBaseLooper.sol";
import {Id, MarketParams} from "./morpho/IMorpho.sol";

interface IBaseMorphoLooper is IBaseLooper {
    function morpho() external view returns (address);

    function marketId() external view returns (Id);
}
