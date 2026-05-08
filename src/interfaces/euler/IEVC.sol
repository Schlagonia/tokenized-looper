// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface IEVC {
    function enableCollateral(address account, address vault) external payable;

    function enableController(address account, address vault) external payable;

    function isCollateralEnabled(
        address account,
        address vault
    ) external view returns (bool);

    function isControllerEnabled(
        address account,
        address vault
    ) external view returns (bool);
}
