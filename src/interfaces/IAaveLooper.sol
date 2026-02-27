// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IBaseLooper} from "./IBaseLooper.sol";
import {IMorpho} from "./morpho/IMorpho.sol";
import {IPoolDataProvider} from "./aave/IPoolDataProvider.sol";
import {IAaveOracle} from "./aave/IAaveOracle.sol";
import {IRewardsController} from "./aave/IRewardsController.sol";

interface IAaveLooper is IBaseLooper {
    function MORPHO() external view returns (IMorpho);

    function POOL() external view returns (address);

    function DATA_PROVIDER() external view returns (IPoolDataProvider);

    function AAVE_ORACLE() external view returns (IAaveOracle);

    function REWARDS_CONTROLLER() external view returns (IRewardsController);

    function A_TOKEN() external view returns (address);

    function VARIABLE_DEBT_TOKEN() external view returns (address);

    function E_MODE_CATEGORY_ID() external view returns (uint8);

    function setAuction(address _auction) external;

    function setUseAuction(bool _useAuction) external;

    function kickAuction(address _token) external returns (uint256);
}
