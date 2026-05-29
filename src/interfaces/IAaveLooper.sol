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

    function claimRewards() external;

    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;

    function setEModeCategory(uint8 _eModeCategoryId) external;

    function setAuction(address _auction) external;

    function kickAuction(address _token) external returns (uint256);
}
