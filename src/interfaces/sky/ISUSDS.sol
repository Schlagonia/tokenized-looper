// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ISUSDS is IERC4626 {
    function deposit(
        uint256 assets,
        address receiver,
        uint16 referral
    ) external returns (uint256 shares);
}
