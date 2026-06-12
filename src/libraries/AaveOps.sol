// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPool} from "../interfaces/aave/IPool.sol";
import {IPoolDataProvider} from "../interfaces/aave/IPoolDataProvider.sol";
import {IAaveOracle} from "../interfaces/aave/IAaveOracle.sol";
import {IRewardsController} from "../interfaces/aave/IRewardsController.sol";

library AaveOps {
    uint256 internal constant VARIABLE_RATE_MODE = 2;
    uint16 internal constant REFERRAL_CODE = 0;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    function getCollateralPrice(
        IAaveOracle oracle,
        address collateralToken,
        address asset,
        uint256 assetDecimals,
        uint256 collateralDecimals
    ) public view returns (uint256) {
        uint256 collateralPrice = oracle.getAssetPrice(collateralToken);
        uint256 assetPrice = oracle.getAssetPrice(asset);

        if (assetPrice == 0) return 0;

        return
            (collateralPrice * (10 ** assetDecimals) * ORACLE_PRICE_SCALE) /
            (assetPrice * (10 ** collateralDecimals));
    }

    function supply(
        address pool,
        address collateralToken,
        uint256 amount
    ) public {
        if (amount == 0) return;
        IPool(pool).supply(
            collateralToken,
            amount,
            address(this),
            REFERRAL_CODE
        );
    }

    function withdraw(
        address pool,
        address collateralToken,
        uint256 amount
    ) public {
        if (amount == 0) return;
        IPool(pool).withdraw(collateralToken, amount, address(this));
    }

    function borrow(address pool, address asset, uint256 amount) public {
        if (amount == 0) return;
        IPool(pool).borrow(
            asset,
            amount,
            VARIABLE_RATE_MODE,
            REFERRAL_CODE,
            address(this)
        );
    }

    function repay(address pool, address asset, uint256 amount) public {
        if (amount == 0) return;
        IPool(pool).repay(asset, amount, VARIABLE_RATE_MODE, address(this));
    }

    function isSupplyPaused(
        IPoolDataProvider dataProvider,
        address collateralToken
    ) public view returns (bool) {
        bool isPaused = dataProvider.getPaused(collateralToken);
        if (isPaused) return true;

        (, , , , , , , , , bool isFrozen) = dataProvider
            .getReserveConfigurationData(collateralToken);
        return isFrozen;
    }

    function isBorrowPaused(
        IPoolDataProvider dataProvider,
        address asset
    ) public view returns (bool) {
        bool isPaused = dataProvider.getPaused(asset);
        if (isPaused) return true;

        (, , , , , , bool borrowingEnabled, , , bool isFrozen) = dataProvider
            .getReserveConfigurationData(asset);
        return isFrozen || !borrowingEnabled;
    }

    function isLiquidatable(address pool) public view returns (bool) {
        (, , , , , uint256 healthFactor) = IPool(pool).getUserAccountData(
            address(this)
        );
        return healthFactor < WAD && healthFactor > 0;
    }

    function maxCollateralDeposit(
        IPoolDataProvider dataProvider,
        address collateralToken,
        uint256 collateralDecimals
    ) public view returns (uint256) {
        (, uint256 supplyCap) = dataProvider.getReserveCaps(collateralToken);
        if (supplyCap == 0) return type(uint256).max;

        uint256 currentSupply = dataProvider.getATokenTotalSupply(
            collateralToken
        );
        uint256 supplyCapInTokens = supplyCap * (10 ** collateralDecimals);

        return
            supplyCapInTokens > currentSupply
                ? supplyCapInTokens - currentSupply
                : 0;
    }

    function maxBorrowAmount(
        address pool,
        IPoolDataProvider dataProvider,
        address asset,
        address assetAToken,
        bool useVirtualBalance,
        uint256 assetDecimals
    ) public view returns (uint256) {
        uint256 virtualLiquidity = useVirtualBalance
            ? IPool(pool).getVirtualUnderlyingBalance(asset)
            : ERC20(asset).balanceOf(assetAToken);

        (uint256 borrowCap, ) = dataProvider.getReserveCaps(asset);
        if (borrowCap == 0) return virtualLiquidity;

        uint256 currentDebt = dataProvider.getTotalDebt(asset);
        uint256 borrowCapInTokens = borrowCap * (10 ** assetDecimals);
        uint256 borrowCapRemaining = borrowCapInTokens > currentDebt
            ? borrowCapInTokens - currentDebt
            : 0;

        return
            borrowCapRemaining < virtualLiquidity
                ? borrowCapRemaining
                : virtualLiquidity;
    }

    function liquidateCollateralFactor(
        address pool,
        IPoolDataProvider dataProvider,
        address collateralToken
    ) public view returns (uint256) {
        uint256 liquidationThreshold;
        uint256 userEModeCategory = IPool(pool).getUserEMode(address(this));
        if (userEModeCategory != 0) {
            liquidationThreshold = IPool(pool)
                .getEModeCategoryData(uint8(userEModeCategory))
                .liquidationThreshold;
            require(liquidationThreshold != 0, "bad emode");
        } else {
            (, , liquidationThreshold, , , , , , , ) = dataProvider
                .getReserveConfigurationData(collateralToken);
        }

        return liquidationThreshold * 1e14;
    }

    function balanceOfCollateral(address aToken) public view returns (uint256) {
        return ERC20(aToken).balanceOf(address(this));
    }

    function balanceOfDebt(
        address variableDebtToken
    ) public view returns (uint256) {
        return ERC20(variableDebtToken).balanceOf(address(this));
    }

    function claimRewards(
        IRewardsController rewardsController,
        address aToken,
        address variableDebtToken
    ) public {
        address[] memory assets = new address[](2);
        assets[0] = aToken;
        assets[1] = variableDebtToken;

        rewardsController.claimAllRewardsToSelf(assets);
    }
}
