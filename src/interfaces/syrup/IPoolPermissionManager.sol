// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IPoolPermissionManager {
    function admin() external view returns (address);

    function hasPermission(
        address poolManager_,
        address lender_,
        bytes32 functionId_
    ) external view returns (bool hasPermission_);

    function setLenderAllowlist(
        address poolManager_,
        address[] calldata lenders_,
        bool[] calldata booleans_
    ) external;
}
