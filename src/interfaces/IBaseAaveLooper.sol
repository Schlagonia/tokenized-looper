// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IBaseLooper} from "./IBaseLooper.sol";

interface IBaseAaveLooper is IBaseLooper {
    function addressesProvider() external view returns (address);

    function pool() external view returns (address);

    function dataProvider() external view returns (address);

    function aaveOracle() external view returns (address);

    function rewardsController() external view returns (address);

    function aToken() external view returns (address);

    function assetAToken() external view returns (address);

    function variableDebtToken() external view returns (address);

    function eModeCategoryId() external view returns (uint8);
}
