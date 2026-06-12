// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMorpho, Id, MarketParams, Position} from "../interfaces/morpho/IMorpho.sol";
import {IOracle} from "../interfaces/morpho/IOracle.sol";
import {MorphoBalancesLib} from "./morpho/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "./morpho/SharesMathLib.sol";

library MorphoOps {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    function getCollateralPrice(
        MarketParams memory marketParams
    ) public view returns (uint256) {
        return IOracle(marketParams.oracle).price();
    }

    function supplyCollateral(
        IMorpho morpho,
        MarketParams memory marketParams,
        uint256 amount
    ) public {
        if (amount == 0) return;
        morpho.supplyCollateral(marketParams, amount, address(this), "");
    }

    function withdrawCollateral(
        IMorpho morpho,
        MarketParams memory marketParams,
        uint256 amount
    ) public {
        if (amount == 0) return;
        morpho.withdrawCollateral(
            marketParams,
            amount,
            address(this),
            address(this)
        );
    }

    function borrow(
        IMorpho morpho,
        MarketParams memory marketParams,
        uint256 amount
    ) public {
        if (amount == 0) return;
        morpho.borrow(marketParams, amount, 0, address(this), address(this));
    }

    function repay(
        IMorpho morpho,
        Id marketId,
        MarketParams memory marketParams,
        uint256 amount
    ) public {
        if (amount == 0) return;
        (
            ,
            ,
            uint256 totalBorrowAssets,
            uint256 totalBorrowShares
        ) = MorphoBalancesLib.expectedMarketBalances(morpho, marketParams);

        uint256 shares = Math.min(
            SharesMathLib.toSharesDown(
                amount,
                totalBorrowAssets,
                totalBorrowShares
            ),
            morpho.position(marketId, address(this)).borrowShares
        );

        morpho.repay(marketParams, 0, shares, address(this), "");
    }

    function isLiquidatable(
        IMorpho morpho,
        Id marketId,
        MarketParams memory marketParams
    ) public view returns (bool) {
        Position memory p = morpho.position(marketId, address(this));
        if (p.borrowShares == 0) return false;

        uint256 collateralValue = (uint256(p.collateral) *
            IOracle(marketParams.oracle).price()) / ORACLE_PRICE_SCALE;
        uint256 maxBorrow = (collateralValue * marketParams.lltv) / WAD;

        return balanceOfDebt(morpho, marketParams) > maxBorrow;
    }

    function maxBorrowAmount(
        IMorpho morpho,
        MarketParams memory marketParams
    ) public view returns (uint256) {
        (
            uint256 totalSupplyAssets,
            ,
            uint256 totalBorrowAssets,

        ) = MorphoBalancesLib.expectedMarketBalances(morpho, marketParams);
        return
            totalSupplyAssets > totalBorrowAssets
                ? totalSupplyAssets - totalBorrowAssets
                : 0;
    }

    function liquidateCollateralFactor(
        MarketParams memory marketParams
    ) public pure returns (uint256) {
        return marketParams.lltv;
    }

    function balanceOfCollateral(
        IMorpho morpho,
        Id marketId
    ) public view returns (uint256) {
        Position memory p = morpho.position(marketId, address(this));
        return p.collateral;
    }

    function balanceOfDebt(
        IMorpho morpho,
        MarketParams memory marketParams
    ) public view returns (uint256) {
        return
            MorphoBalancesLib.expectedBorrowAssets(
                morpho,
                marketParams,
                address(this)
            );
    }
}
