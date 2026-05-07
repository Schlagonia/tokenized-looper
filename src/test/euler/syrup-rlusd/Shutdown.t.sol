// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {ShutdownTest} from "../../base/Shutdown.t.sol";
import {SetupEulerSyrupRLUSD} from "./Setup.sol";

/// @notice syrupUSDC/RLUSD Euler shutdown tests.
contract EulerSyrupRLUSDShutdownTest is SetupEulerSyrupRLUSD, ShutdownTest {
    function setUp() public override(SetupEulerSyrupRLUSD, ShutdownTest) {
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
}
