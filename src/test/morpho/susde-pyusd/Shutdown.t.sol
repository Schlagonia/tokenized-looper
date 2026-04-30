// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../../base/Setup.sol";
import {ShutdownTest} from "../../base/Shutdown.t.sol";
import {SetupSUSDePYUSD} from "./Setup.sol";

contract sUSDePYUSDMorphoShutdownTest is SetupSUSDePYUSD, ShutdownTest {
    /// @dev Multi-hop sUSDe → PYUSD route can leave a touch more residual
    ///      than the base 1 BPS dust tolerance.
    uint256 internal constant SUSDE_SHUTDOWN_DUST_BPS = 15;

    function setUp() public override(SetupSUSDePYUSD, ShutdownTest) {
        SetupSUSDePYUSD.setUp();
    }

    function setUpStrategy()
        public
        override(SetupSUSDePYUSD, Setup)
        returns (address)
    {
        return SetupSUSDePYUSD.setUpStrategy();
    }

    function accrueYield(
        uint256 _amount
    ) public override(SetupSUSDePYUSD, Setup) {
        SetupSUSDePYUSD.accrueYield(_amount);
    }

    function _maxUnwindCollateralDust(
        uint256 collateralBeforeUnwind
    ) internal pure override returns (uint256) {
        uint256 relativeDust = collateralBeforeUnwind /
            (10_000 / SUSDE_SHUTDOWN_DUST_BPS);
        return
            relativeDust > MIN_UNWIND_COLLATERAL_DUST
                ? relativeDust
                : MIN_UNWIND_COLLATERAL_DUST;
    }
}
