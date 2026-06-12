// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPawnBroker} from "pawn-broker/interfaces/IPawnBroker.sol";

library PawnBrokerOps {
    function getCollateralPrice(
        IPawnBroker pawnBroker
    ) public view returns (uint256) {
        return pawnBroker.ORACLE().price();
    }

    function supplyCollateral(IPawnBroker pawnBroker, uint256 amount) public {
        if (amount == 0) return;
        pawnBroker.postCollateral(amount);
    }

    function withdrawCollateral(IPawnBroker pawnBroker, uint256 amount) public {
        if (amount == 0) return;
        pawnBroker.withdrawCollateral(amount, address(this));
    }

    function borrow(IPawnBroker pawnBroker, uint256 amount) public {
        if (amount == 0) return;
        pawnBroker.borrow(amount, address(this));
    }

    function repayDebt(IPawnBroker pawnBroker, uint256 amount) public {
        if (amount == 0) return;
        pawnBroker.repay(amount);
    }

    function isSupplyPaused(IPawnBroker pawnBroker) public view returns (bool) {
        return pawnBroker.paused();
    }

    function isBorrowPaused(IPawnBroker pawnBroker) public view returns (bool) {
        return
            pawnBroker.paused() ||
            pawnBroker.isShutdown() ||
            pawnBroker.calledDebt() > 0;
    }

    function isLiquidatable(IPawnBroker pawnBroker) public view returns (bool) {
        return !pawnBroker.paused() && !pawnBroker.isHealthy();
    }

    function maxBorrowAmount(
        IPawnBroker pawnBroker,
        address asset
    ) public view returns (uint256) {
        uint256 marketBalance = ERC20(asset).balanceOf(address(pawnBroker));
        uint256 maxDebt = pawnBroker.maxDebt();
        uint256 totalDebt = pawnBroker.totalDebt();

        if (maxDebt <= totalDebt) return 0;

        return Math.min(maxDebt - totalDebt, marketBalance);
    }

    function liquidateCollateralFactor(
        IPawnBroker pawnBroker
    ) public view returns (uint256) {
        return pawnBroker.LLTV();
    }

    function balanceOfCollateral(
        IPawnBroker pawnBroker
    ) public view returns (uint256) {
        return pawnBroker.totalCollateral();
    }

    function balanceOfDebt(
        IPawnBroker pawnBroker
    ) public view returns (uint256) {
        return pawnBroker.totalDebt();
    }
}
