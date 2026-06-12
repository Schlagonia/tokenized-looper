// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IEVault} from "../interfaces/euler/IEVault.sol";
import {IEulerPriceOracle} from "../interfaces/euler/IEulerPriceOracle.sol";

library EulerOps {
    uint32 internal constant OP_DEPOSIT = 1 << 0;
    uint32 internal constant OP_WITHDRAW = 1 << 2;
    uint32 internal constant OP_BORROW = 1 << 6;
    uint32 internal constant OP_REPAY = 1 << 7;
    uint32 internal constant OP_TOUCH = 1 << 13;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    function accrueInterest(IEVault borrowVault) public {
        if (!isOperationDisabled(borrowVault, OP_TOUCH)) borrowVault.touch();
    }

    function getCollateralPrice(
        IEVault collateralVault,
        IEulerPriceOracle oracle,
        address unitOfAccount,
        address asset,
        uint256 collateralUnit,
        uint256 assetUnit
    ) public view returns (uint256) {
        uint256 collateralShares = collateralVault.convertToShares(
            collateralUnit
        );

        uint256 collateralValue = quoteToUnitOfAccount(
            oracle,
            unitOfAccount,
            collateralShares,
            address(collateralVault)
        );
        uint256 assetValue = quoteToUnitOfAccount(
            oracle,
            unitOfAccount,
            assetUnit,
            asset
        );

        if (assetValue == 0) return 0;

        uint256 scaledCollateralValue = Math.mulDiv(
            collateralValue,
            ORACLE_PRICE_SCALE,
            collateralUnit
        );
        return Math.mulDiv(scaledCollateralValue, assetUnit, assetValue);
    }

    function quoteToUnitOfAccount(
        IEulerPriceOracle oracle,
        address unitOfAccount,
        uint256 amount,
        address base
    ) public view returns (uint256) {
        return
            base == unitOfAccount
                ? amount
                : oracle.getQuote(amount, base, unitOfAccount);
    }

    function supplyCollateral(IEVault collateralVault, uint256 amount) public {
        if (amount == 0) return;
        collateralVault.deposit(amount, address(this));
    }

    function withdrawCollateral(
        IEVault collateralVault,
        uint256 amount
    ) public {
        if (amount == 0) return;
        collateralVault.withdraw(amount, address(this), address(this));
    }

    function borrow(IEVault borrowVault, uint256 amount) public {
        if (amount == 0) return;
        borrowVault.borrow(amount, address(this));
    }

    function repay(IEVault borrowVault, uint256 amount) public {
        if (amount == 0) return;

        uint256 debt = balanceOfDebt(borrowVault);
        if (debt == 0) return;

        borrowVault.repay(
            amount >= debt ? type(uint256).max : amount,
            address(this)
        );
    }

    function isSupplyPaused(
        IEVault collateralVault
    ) public view returns (bool) {
        if (isOperationDisabled(collateralVault, OP_DEPOSIT)) return true;
        return collateralVault.maxDeposit(address(this)) == 0;
    }

    function isBorrowPaused(
        IEVault borrowVault,
        IEVault collateralVault
    ) public view returns (bool) {
        if (isOperationDisabled(borrowVault, OP_BORROW)) return true;
        return
            borrowVault.LTVBorrow(address(collateralVault)) == 0 ||
            maxBorrowAmount(borrowVault) == 0;
    }

    function isLiquidatable(IEVault borrowVault) public view returns (bool) {
        if (balanceOfDebt(borrowVault) == 0) return false;

        (uint256 collateralValue, uint256 liabilityValue) = borrowVault
            .accountLiquidity(address(this), true);

        return liabilityValue > collateralValue;
    }

    function maxCollateralDeposit(
        IEVault collateralVault
    ) public view returns (uint256) {
        (uint16 encodedSupplyCap, ) = collateralVault.caps();
        if (encodedSupplyCap == 0) return type(uint256).max;

        return collateralVault.maxDeposit(address(this));
    }

    function maxBorrowAmount(
        IEVault borrowVault
    ) public view returns (uint256) {
        uint256 cash = borrowVault.cash();

        (, uint16 encodedBorrowCap) = borrowVault.caps();
        uint256 borrowCap = resolveAmountCap(encodedBorrowCap);
        if (borrowCap == type(uint256).max) return cash;

        uint256 borrows = borrowVault.totalBorrows();
        uint256 capRemaining = borrowCap > borrows ? borrowCap - borrows : 0;

        return Math.min(cash, capRemaining);
    }

    function liquidateCollateralFactor(
        IEVault borrowVault,
        IEVault collateralVault
    ) public view returns (uint256) {
        return
            uint256(borrowVault.LTVLiquidation(address(collateralVault))) *
            1e14;
    }

    function balanceOfCollateral(
        IEVault collateralVault
    ) public view returns (uint256) {
        return
            collateralVault.convertToAssets(
                collateralVault.balanceOf(address(this))
            );
    }

    function balanceOfDebt(IEVault borrowVault) public view returns (uint256) {
        return borrowVault.debtOf(address(this));
    }

    function isOperationDisabled(
        IEVault vault,
        uint32 operation
    ) public view returns (bool) {
        (address hookTarget, uint32 hookedOps) = vault.hookConfig();
        return (hookedOps & operation) != 0 && hookTarget.code.length == 0;
    }

    function resolveAmountCap(uint16 encodedCap) public pure returns (uint256) {
        if (encodedCap == 0) return type(uint256).max;

        uint256 exponent = encodedCap & 63;
        uint256 mantissa = encodedCap >> 6;

        return (mantissa * (10 ** exponent)) / 100;
    }
}
