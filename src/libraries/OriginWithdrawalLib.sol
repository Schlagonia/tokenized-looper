// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IOUSDVault} from "../interfaces/origin/IOUSDVault.sol";

library OriginWithdrawalLib {
    using SafeERC20 for ERC20;

    address internal constant OUSD = 0x2A8e1E676Ec238d8A992307B495b45B3fEAa5e86;
    address internal constant WOUSD =
        0xD2af830E8CBdFed6CC11Bab697bB25496ed6FA62;
    address internal constant OUSD_VAULT =
        0xE75D77B1865Ae93c7eaa3040B038D7aA7BC02F70;

    function balanceOfUnderlying() external view returns (uint256) {
        return ERC20(OUSD).balanceOf(address(this));
    }

    function initiate(
        uint256 shares
    ) external returns (uint256 requestId, uint256 pendingAssets) {
        pendingAssets = IERC4626(WOUSD).redeem(
            shares,
            address(this),
            address(this)
        );

        ERC20(OUSD).forceApprove(OUSD_VAULT, pendingAssets);
        (requestId, ) = IOUSDVault(OUSD_VAULT).requestWithdrawal(pendingAssets);
    }

    function claim(uint256 requestId) external returns (uint256 assets) {
        assets = IOUSDVault(OUSD_VAULT).claimWithdrawal(requestId);
    }
}
