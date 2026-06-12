// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupEulerSyrupRLUSD} from "./Setup.sol";
import {EulerLooper} from "../../../euler/EulerLooper.sol";
import {IEVault} from "../../../interfaces/euler/IEVault.sol";
import {IEulerPriceOracle} from "../../../interfaces/euler/IEulerPriceOracle.sol";
import {MetaExchange} from "../../../periphery/MetaExchange.sol";

/// @notice syrupUSDC/RLUSD Euler operation tests.
contract EulerSyrupRLUSDOperationTest is SetupEulerSyrupRLUSD, OperationTest {
    function setUp() public override(SetupEulerSyrupRLUSD, OperationTest) {
        SetupEulerSyrupRLUSD.setUp();
    }

    function setUpStrategy()
        public
        override(SetupEulerSyrupRLUSD, Setup)
        returns (address)
    {
        return SetupEulerSyrupRLUSD.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupEulerSyrupRLUSD, Setup) {
        SetupEulerSyrupRLUSD.accrueYield(_amount);
    }

    function _maxUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure override returns (uint256) {
        uint256 relativeDust = (collateralBeforeUnwind * 5) / 10_000;
        return
            relativeDust > MIN_UNWIND_COLLATERAL_DUST
                ? relativeDust
                : MIN_UNWIND_COLLATERAL_DUST;
    }

    function test_eulerMarketConfigured() public view {
        EulerLooper looper = EulerLooper(payable(address(strategy)));

        assertEq(
            address(looper.COLLATERAL_VAULT()),
            EULER_SYRUP_USDC_VAULT,
            "!collateral vault"
        );
        assertEq(
            address(looper.BORROW_VAULT()),
            EULER_RLUSD_VAULT,
            "!borrow vault"
        );
        assertEq(address(looper.EVC()), EVC, "!evc");
        assertEq(
            address(looper.ORACLE()),
            IEVault(EULER_RLUSD_VAULT).oracle(),
            "!oracle"
        );
        assertEq(
            looper.UNIT_OF_ACCOUNT(),
            IEVault(EULER_RLUSD_VAULT).unitOfAccount(),
            "!unit"
        );
        assertEq(
            IEVault(EULER_SYRUP_USDC_VAULT).asset(),
            SYRUP_USDC,
            "!collateral asset"
        );
        assertEq(IEVault(EULER_RLUSD_VAULT).asset(), RLUSD, "!borrow asset");
        assertEq(strategy.getLiquidateCollateralFactor(), 0.89e18, "!lltv");

        _assertEulerAccountEnabled(address(strategy));
    }

    function test_exchange_routes_areConfiguredForEulerMarket() public view {
        MetaExchange.RouteStep[] memory forward = exchange.getRoute(
            RLUSD,
            SYRUP_USDC
        );
        assertEq(forward.length, 2, "!forward length");
        assertEq(forward[0].exchange, address(curveExchange), "!forward ex 0");
        assertEq(forward[0].tokenTo, USDC, "!forward token 0");
        assertEq(forward[1].exchange, address(syrupExchange), "!forward ex 1");
        assertEq(forward[1].tokenTo, SYRUP_USDC, "!forward token 1");

        MetaExchange.RouteStep[] memory reverse = exchange.getRoute(
            SYRUP_USDC,
            RLUSD
        );
        assertEq(reverse.length, 2, "!reverse length");
        assertEq(reverse[0].exchange, address(uniExchange), "!reverse ex 0");
        assertEq(reverse[0].tokenTo, USDC, "!reverse token 0");
        assertEq(reverse[1].exchange, address(curveExchange), "!reverse ex 1");
        assertEq(reverse[1].tokenTo, RLUSD, "!reverse token 1");
    }

    function test_routeDrivenTend_worksWithEulerMarket() public {
        uint256 amount = 10_000e18;

        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.tend();

        assertGt(strategy.balanceOfCollateral(), 0, "!collateral");
        assertGt(strategy.balanceOfDebt(), 0, "!debt");
        _assertEulerAccountEnabled(address(strategy));
    }

    function test_positionPricing_matchesEulerCollateralVaultOracle() public {
        uint256 amount = 10_000e18;

        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.tend();

        (uint256 looperCollateralValue, ) = strategy.position();

        uint256 collateralUnit = 10 ** ERC20(SYRUP_USDC).decimals();
        uint256 collateralShares = IEVault(EULER_SYRUP_USDC_VAULT)
            .convertToShares(collateralUnit);
        IEulerPriceOracle oracle = IEulerPriceOracle(
            IEVault(EULER_RLUSD_VAULT).oracle()
        );
        address unitOfAccount = IEVault(EULER_RLUSD_VAULT).unitOfAccount();

        uint256 collateralUnitValue = _quoteToUnitOfAccount(
            oracle,
            collateralShares,
            EULER_SYRUP_USDC_VAULT,
            unitOfAccount
        );
        uint256 assetValue = _quoteToUnitOfAccount(
            oracle,
            10 ** ERC20(RLUSD).decimals(),
            RLUSD,
            unitOfAccount
        );

        uint256 scaledCollateralValue = Math.mulDiv(
            collateralUnitValue,
            1e36,
            collateralUnit
        );
        uint256 price = Math.mulDiv(
            scaledCollateralValue,
            10 ** ERC20(RLUSD).decimals(),
            assetValue
        );
        uint256 expectedCollateralValue = Math.mulDiv(
            strategy.balanceOfCollateral(),
            price,
            1e36
        );

        assertEq(
            looperCollateralValue,
            expectedCollateralValue,
            "!collateral value"
        );
    }

    function _quoteToUnitOfAccount(
        IEulerPriceOracle oracle,
        uint256 amount,
        address base,
        address unitOfAccount
    ) internal view returns (uint256) {
        return
            base == unitOfAccount
                ? amount
                : oracle.getQuote(amount, base, unitOfAccount);
    }
}
