// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IOUSD} from "../../interfaces/origin/IOUSD.sol";
import {IOUSDVault} from "../../interfaces/origin/IOUSDVault.sol";
import {BaseCooldownAdapter} from "./BaseCooldownAdapter.sol";

contract OriginCooldownAdapter is BaseCooldownAdapter {
    using SafeERC20 for ERC20;

    address public immutable UNDERLYING;
    address public immutable VAULT_ADDRESS;
    uint256 public immutable scaler;

    uint256 public pendingWithdrawalAssets;

    constructor(address _strategy) BaseCooldownAdapter(_strategy) {
        UNDERLYING = IERC4626(collateralToken).asset();
        VAULT_ADDRESS = IOUSD(UNDERLYING).vaultAddress();
        require(IOUSDVault(VAULT_ADDRESS).asset() == asset, "!vault asset");

        uint256 underlyingDecimals = ERC20(UNDERLYING).decimals();
        uint256 assetDecimals = ERC20(asset).decimals();
        require(underlyingDecimals >= assetDecimals, "!decimals");
        scaler = 10 ** (underlyingDecimals - assetDecimals);
    }

    function pendingValue() external view override returns (uint256) {
        uint256 pendingAssets = pendingWithdrawalAssets;
        if (pendingAssets == 0) return 0;

        return
            IERC4626(collateralToken).convertToShares(pendingAssets * scaler);
    }

    function tokenValue(
        address token,
        uint256 amount
    ) public view override returns (uint256) {
        if (token == UNDERLYING) {
            return IERC4626(collateralToken).convertToShares(amount);
        }
        if (token == asset) {
            return IERC4626(collateralToken).convertToShares(amount * scaler);
        }
        return amount;
    }

    function initiate(
        uint256 collateralAmount,
        bytes calldata
    ) external override onlyStrategy returns (bytes memory) {
        require(pendingWithdrawalAssets == 0, "pending withdrawals");
        require(collateralAmount > 0, "!shares");

        ERC20(collateralToken).safeTransferFrom(
            STRATEGY,
            address(this),
            collateralAmount
        );
        uint256 underlyingAmount = IERC4626(collateralToken).redeem(
            collateralAmount,
            address(this),
            address(this)
        );

        ERC20(UNDERLYING).forceApprove(VAULT_ADDRESS, underlyingAmount);
        (uint256 requestId, ) = IOUSDVault(VAULT_ADDRESS).requestWithdrawal(
            underlyingAmount
        );
        pendingWithdrawalAssets = underlyingAmount / scaler;

        return abi.encode(requestId, underlyingAmount);
    }

    function claim(
        bytes calldata data
    ) external override onlyStrategy returns (bytes memory) {
        uint256 requestId = abi.decode(data, (uint256));
        uint256 assets = IOUSDVault(VAULT_ADDRESS).claimWithdrawal(requestId);

        uint256 pending = pendingWithdrawalAssets;
        pendingWithdrawalAssets = assets < pending ? pending - assets : 0;

        ERC20(asset).safeTransfer(STRATEGY, assets);
        return abi.encode(assets);
    }

    function clear(bytes calldata) external override onlyStrategy {
        delete pendingWithdrawalAssets;
    }
}
