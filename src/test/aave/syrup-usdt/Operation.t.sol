// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupAaveSyrupUSDT} from "./Setup.sol";
import {MetaExchange} from "../../../periphery/exchanges/MetaExchange.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Aave syrupUSDT operation tests
contract AaveSyrupUSDTOperationTest is SetupAaveSyrupUSDT, OperationTest {
    function setUp() public override(SetupAaveSyrupUSDT, OperationTest) {
        SetupAaveSyrupUSDT.setUp();
    }

    function setUpStrategy()
        public
        override(SetupAaveSyrupUSDT, Setup)
        returns (address)
    {
        return SetupAaveSyrupUSDT.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupAaveSyrupUSDT, Setup) {
        SetupAaveSyrupUSDT.accrueYield(_amount);
    }

    function test_zeroPendingRedemptions_onlyEmergencyAuthorized() public {
        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        strategy.clearCooldown("");

        vm.prank(emergencyAdmin);
        strategy.clearCooldown("");
    }

    function test_setExchange_onlyGovernance() public {
        MetaExchange newExchange = new MetaExchange(WETH);

        vm.prank(user);
        vm.expectRevert("!governance");
        strategy.setExchange(address(newExchange));

        vm.prank(management);
        strategy.setExchange(address(newExchange));
    }

    function test_exchange_setV4Pool_onlyGovernanceOrOperator() public {
        vm.prank(user);
        vm.expectRevert("!operator");
        uniExchange.setV4Pool(USDT, SYRUP_USDT, bytes32(uint256(123)));

        vm.prank(management);
        uniExchange.setV4Pool(USDT, SYRUP_USDT, bytes32(uint256(123)));
    }

    function test_exchange_setUniFees_onlyGovernanceOrOperator() public {
        vm.prank(user);
        vm.expectRevert("!operator");
        uniExchange.setUniFees(USDT, SYRUP_USDT, 500);

        vm.prank(management);
        uniExchange.setUniFees(USDT, SYRUP_USDT, 500);
    }

    function test_exchange_swap_isNotStrategyGated() public {
        vm.prank(user);
        uint256 amountOut = exchange.exchange(USDT, SYRUP_USDT, 0, 0);
        assertEq(amountOut, 0, "!amountOut");
    }

    function test_exchange_setUniBase_onlyGovernanceOrOperator() public {
        vm.prank(user);
        vm.expectRevert("!operator");
        uniExchange.setUniBase(WETH);

        vm.prank(management);
        uniExchange.setUniBase(WETH);
    }

    function test_exchange_setSyrupDepositConfig_onlyGovernanceOrOperator()
        public
    {
        vm.prank(user);
        vm.expectRevert("!operator");
        syrupExchange.setSyrupDepositConfig(
            SYRUP_USDT,
            SYRUP_USDT_ROUTER,
            bytes32("Maple")
        );

        vm.prank(management);
        syrupExchange.setSyrupDepositConfig(
            SYRUP_USDT,
            SYRUP_USDT_ROUTER,
            bytes32("Maple")
        );

        (address router, bytes32 depositData) = syrupExchange
            .syrupDepositConfigs(SYRUP_USDT);
        assertEq(router, SYRUP_USDT_ROUTER, "!router");
        assertEq(depositData, bytes32("Maple"), "!depositData");
    }

    function test_exchange_routes_areConfiguredForSyrupUsdt() public view {
        MetaExchange.RouteStep[] memory forward = exchange.getRoute(
            USDT,
            SYRUP_USDT
        );
        assertEq(forward.length, 1, "!forward length");
        assertEq(
            forward[0].exchange,
            useMint ? address(syrupExchange) : address(uniExchange),
            "!forward exchange"
        );
        assertEq(forward[0].tokenTo, SYRUP_USDT, "!forward token");

        MetaExchange.RouteStep[] memory reverse = exchange.getRoute(
            SYRUP_USDT,
            USDT
        );
        assertEq(reverse.length, 1, "!reverse length");
        assertEq(reverse[0].exchange, address(uniExchange), "!reverse ex");
        assertEq(reverse[0].tokenTo, USDT, "!reverse token");
    }

    function test_exchange_routeDrivenDeposit_worksWhenMapleAuthorized()
        public
    {
        if (!useMint) return;

        uint256 amount = 10_000e6;

        mintAndDepositIntoStrategy(strategy, user, amount);

        uint256 collateralBefore = ERC20(SYRUP_USDT).balanceOf(
            address(strategy)
        );
        vm.prank(address(strategy));
        exchange.exchange(USDT, SYRUP_USDT, amount, 0);
        uint256 collateralAfter = ERC20(SYRUP_USDT).balanceOf(
            address(strategy)
        );

        assertGt(collateralAfter, collateralBefore, "!collateral minted");
    }

    function test_exchange_sweep_onlyGovernance() public {
        address gov = management;

        deal(USDT, address(exchange), 1_000e6);

        vm.prank(user);
        vm.expectRevert("!governance");
        exchange.sweep(USDT, type(uint256).max);

        uint256 beforeBal = ERC20(USDT).balanceOf(gov);
        vm.prank(gov);
        exchange.sweep(USDT, type(uint256).max);

        assertEq(ERC20(USDT).balanceOf(address(exchange)), 0, "!swept");
        assertEq(ERC20(USDT).balanceOf(gov), beforeBal + 1_000e6, "!recv");
    }

    function test_exchange_sweep_ethNotSupported() public {
        address gov = management;

        vm.prank(gov);
        vm.expectRevert("!token");
        exchange.sweep(address(0), type(uint256).max);
    }
}
