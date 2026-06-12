// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICapToken} from "../interfaces/cap/ICapToken.sol";
import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title CapUSDExchange
 * @notice Venue-specific Cap mint/stake and unstake/burn exchange for direct looper routes.
 */
contract CapUSDExchange is BaseExchange {
    using SafeERC20 for ERC20;

    address public immutable asset;
    address public immutable capToken;
    address public immutable stakedCapToken;
    mapping(address => bool) public allowed;

    event AllowedSet(address indexed account, bool allowed);

    constructor(
        address _asset,
        address _capToken,
        address _stakedCapToken,
        address _governance
    ) BaseExchange(_governance) {
        require(
            _asset != address(0) &&
                _capToken != address(0) &&
                _stakedCapToken != address(0),
            "!cap"
        );
        asset = _asset;
        capToken = _capToken;
        stakedCapToken = _stakedCapToken;
    }

    function name() external pure override returns (string memory) {
        return "CapUSDExchange";
    }

    function setAllowed(
        address account,
        bool isAllowed
    ) external onlyGovernance {
        require(account != address(0), "!account");
        allowed[account] = isAllowed;
        emit AllowedSet(account, isAllowed);
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256
    ) internal override returns (uint256 amountOut) {
        if (from == asset && to == stakedCapToken) {
            require(allowed[msg.sender], "!allowed");

            ERC20(from).forceApprove(capToken, amountIn);
            uint256 mintedCapAmount = ICapToken(capToken).mint(
                asset,
                amountIn,
                0,
                address(this),
                block.timestamp
            );

            ERC20(capToken).forceApprove(stakedCapToken, mintedCapAmount);
            return
                IERC4626(stakedCapToken).deposit(
                    mintedCapAmount,
                    address(this)
                );
        }

        require(from == stakedCapToken && to == asset, "!cap");
        uint256 redeemedCapAmount = IERC4626(stakedCapToken).redeem(
            amountIn,
            address(this),
            address(this)
        );

        ERC20(capToken).forceApprove(capToken, redeemedCapAmount);
        amountOut = ICapToken(capToken).burn(
            asset,
            redeemedCapAmount,
            0,
            address(this),
            block.timestamp
        );
    }
}
