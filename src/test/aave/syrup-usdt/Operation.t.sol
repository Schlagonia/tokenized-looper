// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {OperationTest} from "../../base/Operation.t.sol";
import {SetupAaveSyrupUSDT} from "./Setup.sol";
import {SyrupUSDTAaveLooper} from "../../../aave/SyrupUSDTAaveLooper.sol";
import {UniswapUniversalSwapperExchange} from "../../../periphery/UniswapUniversalSwapperExchange.sol";
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
        SyrupUSDTAaveLooper looper = SyrupUSDTAaveLooper(
            payable(address(strategy))
        );

        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        looper.zeroPendingRedemptions();

        vm.prank(emergencyAdmin);
        looper.zeroPendingRedemptions();
    }

    function test_setExchange_onlyGovernance() public {
        SyrupUSDTAaveLooper looper = SyrupUSDTAaveLooper(
            payable(address(strategy))
        );
        UniswapUniversalSwapperExchange newExchange = new UniswapUniversalSwapperExchange(
                WETH
            );

        vm.prank(user);
        vm.expectRevert("!governance");
        looper.setExchange(address(newExchange));

        vm.prank(management);
        looper.setExchange(address(newExchange));
    }

    function test_exchange_setV4Pool_onlyManagement() public {
        UniswapUniversalSwapperExchange syrupExchange = exchange;

        vm.prank(user);
        vm.expectRevert("!management");
        syrupExchange.setV4Pool(USDT, SYRUP_USDT, bytes32(uint256(123)));

        vm.prank(management);
        syrupExchange.setV4Pool(USDT, SYRUP_USDT, bytes32(uint256(123)));
    }

    function test_exchange_setUniFees_onlyManagement() public {
        UniswapUniversalSwapperExchange syrupExchange = exchange;

        vm.prank(user);
        vm.expectRevert("!management");
        syrupExchange.setUniFees(USDT, SYRUP_USDT, 500);

        vm.prank(management);
        syrupExchange.setUniFees(USDT, SYRUP_USDT, 500);
    }

    function test_exchange_swap_onlyStrategy() public {
        UniswapUniversalSwapperExchange syrupExchange = exchange;

        vm.prank(user);
        vm.expectRevert("!strategy");
        syrupExchange.exchange(USDT, SYRUP_USDT, 0, 0);
    }

    function test_exchange_setBase_onlyManagement() public {
        UniswapUniversalSwapperExchange syrupExchange = exchange;

        vm.prank(user);
        vm.expectRevert("!management");
        syrupExchange.setBase(WETH);

        vm.prank(management);
        syrupExchange.setBase(WETH);
    }

    function test_exchange_sweep_onlyGovernance() public {
        UniswapUniversalSwapperExchange syrupExchange = exchange;
        address gov = management;

        deal(USDT, address(syrupExchange), 1_000e6);

        vm.prank(user);
        vm.expectRevert("!governance");
        syrupExchange.sweep(USDT, type(uint256).max);

        uint256 beforeBal = ERC20(USDT).balanceOf(gov);
        vm.prank(gov);
        syrupExchange.sweep(USDT, type(uint256).max);

        assertEq(ERC20(USDT).balanceOf(address(syrupExchange)), 0, "!swept");
        assertEq(ERC20(USDT).balanceOf(gov), beforeBal + 1_000e6, "!recv");
    }

    function test_exchange_sweep_ethNotSupported() public {
        UniswapUniversalSwapperExchange syrupExchange = exchange;
        address gov = management;

        vm.prank(gov);
        vm.expectRevert("!token");
        syrupExchange.sweep(address(0), type(uint256).max);
    }
}
