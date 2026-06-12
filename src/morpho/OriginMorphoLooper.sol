// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MorphoLooper} from "./MorphoLooper.sol";
import {Id} from "../interfaces/morpho/IMorpho.sol";
import {IExchange} from "../interfaces/IExchange.sol";
import {IOUSDVault} from "../interfaces/origin/IOUSDVault.sol";

/**
 * @title OriginMorphoLooper
 * @notice Morpho looper for wrapped Origin collateral (e.g. wOUSD) with async vault withdrawals.
 */
contract OriginMorphoLooper is MorphoLooper {
    using SafeERC20 for ERC20;

    address internal constant OUSD = 0x2A8e1E676Ec238d8A992307B495b45B3fEAa5e86;
    address internal constant WOUSD =
        0xD2af830E8CBdFed6CC11Bab697bB25496ed6FA62;
    address internal constant OUSD_VAULT =
        0xE75D77B1865Ae93c7eaa3040B038D7aA7BC02F70;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 internal constant USDC_TO_OUSD_SCALE = 1e12;

    uint256 public pendingWithdrawalAssets;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId,
        address _exchange,
        address _governance
    )
        MorphoLooper(
            _asset,
            _name,
            _collateralToken,
            _morpho,
            _marketId,
            _exchange,
            _governance
        )
    {}

    function totalCollateralBalance() public view override returns (uint256) {
        uint256 ousdAssets = pendingWithdrawalAssets;
        // If OUSD is the strategy asset, loose OUSD is already counted as asset.
        if (OUSD != address(asset)) {
            ousdAssets += balanceOfOUSD();
        }

        if (USDC != address(asset)) {
            ousdAssets += _usdcToOUSD(balanceOfUnderlying());
        }

        return
            super.totalCollateralBalance() +
            IERC4626(address(collateralToken)).convertToShares(ousdAssets);
    }

    function balanceOfUnderlying() public view returns (uint256) {
        return ERC20(USDC).balanceOf(address(this));
    }

    function balanceOfOUSD() public view returns (uint256) {
        return ERC20(OUSD).balanceOf(address(this));
    }

    function protectedTokens()
        public
        view
        override
        returns (address[] memory _protected)
    {
        _protected = new address[](4);
        _protected[0] = address(asset);
        _protected[1] = collateralToken;
        _protected[2] = OUSD;
        _protected[3] = USDC;
    }

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        require(pendingWithdrawalAssets == 0, "pending withdrawals");
        return super._harvestAndReport();
    }

    function initiateCooldown(
        uint256 _shares
    )
        external
        onlyManagement
        returns (uint256 requestId, uint256 underlyingAmount)
    {
        require(pendingWithdrawalAssets == 0, "pending withdrawals");

        _shares = Math.min(_shares, balanceOfCollateralToken());
        require(_shares > 0, "!shares");

        underlyingAmount = IERC4626(WOUSD).redeem(
            _shares,
            address(this),
            address(this)
        );

        (requestId, ) = IOUSDVault(OUSD_VAULT).requestWithdrawal(
            underlyingAmount
        );

        pendingWithdrawalAssets = underlyingAmount;
    }

    function claimCooldown(
        uint256 requestId
    ) external onlyKeepers returns (uint256 assets) {
        assets = IOUSDVault(OUSD_VAULT).claimWithdrawal(requestId);
        pendingWithdrawalAssets = 0;
    }

    function convertUnderlyingToAsset(
        uint256 amount
    ) external onlyKeepers returns (uint256) {
        require(USDC != address(asset), "!underlying");
        amount = Math.min(amount, balanceOfUnderlying());
        if (amount == 0) return 0;

        uint256 expectedAmountOut = _collateralToAsset(
            IERC4626(collateralToken).convertToShares(_usdcToOUSD(amount))
        );
        _updateSlippageLossLimit();

        ERC20(USDC).forceApprove(exchange, amount);
        uint256 amountOut = IExchange(exchange).exchange(
            USDC,
            address(asset),
            amount,
            0
        );
        _recordSlippage(expectedAmountOut, amountOut);

        return amountOut;
    }

    function _usdcToOUSD(uint256 amount) internal pure returns (uint256) {
        return amount * USDC_TO_OUSD_SCALE;
    }
}
