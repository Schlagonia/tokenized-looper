// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";
import {IBaseLooper} from "../interfaces/IBaseLooper.sol";
import {IBaseMorphoLooper} from "../interfaces/IBaseMorphoLooper.sol";
import {IMorpho, Id, MarketParams, Market} from "../interfaces/morpho/IMorpho.sol";
import {IIrm} from "../interfaces/morpho/IIrm.sol";
import {IOracle as IMorphoOracle} from "../interfaces/morpho/IOracle.sol";
import {MorphoBalancesLib} from "../libraries/morpho/periphery/MorphoBalancesLib.sol";
import {IPPrincipalToken} from "@periphery/interfaces/Pendle/IPendle.sol";

interface IAprOracle {
    function getStrategyApr(
        address _strategy,
        int256 _debtChange
    ) external view returns (uint256);
}

interface IPendleOracle {
    function getPtToAssetRate(
        address market,
        uint32 duration
    ) external view returns (uint256);
}

contract StrategyAprOracle is AprOracleBase {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 31_556_952;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    uint32 public ptTwapDuration = 900;

    address public constant GLOBAL_APR_ORACLE =
        0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92;

    address public constant PENDLE_ORACLE =
        0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;

    event UpdatePtTwapDuration(uint32 duration);

    constructor(
        address _governance
    ) AprOracleBase("Looper Strategy Apr Oracle", _governance) {}

    function setPtTwapDuration(uint32 _duration) external onlyGovernance {
        require(_duration != 0, "duration");
        ptTwapDuration = _duration;
        emit UpdatePtTwapDuration(_duration);
    }

    /**
     * @notice Will return the expected Apr of a strategy post a debt change.
     * @dev _delta is a signed integer so that it can also represent a debt
     * decrease.
     *
     * This should return the annual expected return at the current timestamp
     * represented as 1e18.
     *
     *      ie. 10% == 1e17
     *
     * _delta will be == 0 to get the current apr.
     *
     * This will potentially be called during non-view functions so gas
     * efficiency should be taken into account.
     *
     * @param _strategy The token to get the apr for.
     * @param _delta The difference in debt.
     * @return . The expected apr for the strategy represented as 1e18.
     */
    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view override returns (uint256) {
        uint256 leverage = IBaseLooper(_strategy).targetLeverageRatio();
        if (leverage == 0) return 0;

        uint256 baseAssets = IBaseLooper(_strategy).estimatedTotalAssets();
        if (baseAssets == 0 && _delta <= 0) return 0;
        int256 equityAfterInt = int256(baseAssets) + _delta;
        if (equityAfterInt <= 0) equityAfterInt = 0;
        uint256 equityAfter = uint256(equityAfterInt);

        uint256 collateralValue = (equityAfter * leverage) / WAD;
        int256 debtDelta = (_delta * int256(leverage - WAD)) / int256(WAD);

        uint256 borrowApr = _getBorrowApr(_strategy, debtDelta);
        uint256 collateralApr = _getCollateralApr(
            _strategy,
            _delta,
            leverage,
            collateralValue
        );

        uint256 netApr = _netApr(leverage, collateralApr, borrowApr);

        return netApr;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _getBorrowApr(
        address _strategy,
        int256 debtDelta
    ) internal view returns (uint256) {
        (address morpho, Id marketId) = _getMorphoData(_strategy);
        IMorpho morphoContract = IMorpho(morpho);
        MarketParams memory marketParams = morphoContract.idToMarketParams(
            marketId
        );

        (
            uint256 totalSupplyAssets,
            ,
            uint256 totalBorrowAssets,

        ) = MorphoBalancesLib.expectedMarketBalances(
                morphoContract,
                marketParams
            );

        int256 adjustedBorrowAssets = int256(totalBorrowAssets) + debtDelta;
        if (adjustedBorrowAssets < 0) adjustedBorrowAssets = 0;

        Market memory market = morphoContract.market(marketId);
        market.totalSupplyAssets = uint128(totalSupplyAssets);
        market.totalBorrowAssets = uint128(uint256(adjustedBorrowAssets));
        market.lastUpdate = uint128(block.timestamp);

        uint256 borrowRatePerSecond = IIrm(marketParams.irm).borrowRateView(
            marketParams,
            market
        );

        return borrowRatePerSecond * SECONDS_PER_YEAR;
    }

    function _getCollateralApr(
        address _strategy,
        int256 assetDelta,
        uint256 leverage,
        uint256 collateralValue
    ) internal view returns (uint256) {
        int256 collateralDeltaAsset = (assetDelta * int256(leverage)) /
            int256(WAD);

        (bool isPt, address pendleMarket) = _getPendleMarket(_strategy);
        if (isPt) {
            address ptToken = IBaseLooper(_strategy).collateralToken();
            uint256 price = IPendleOracle(PENDLE_ORACLE).getPtToAssetRate(
                pendleMarket,
                ptTwapDuration
            );
            uint64 slippageBps = IBaseLooper(_strategy).slippage();
            price = _applyPtPriceImpact(
                price,
                collateralDeltaAsset,
                collateralValue,
                slippageBps
            );
            return _getPtAprFromPrice(ptToken, price);
        }

        int256 collateralDelta = _assetToCollateralDelta(
            _strategy,
            collateralDeltaAsset
        );

        address collateralToken = IBaseLooper(_strategy).collateralToken();
        return
            IAprOracle(GLOBAL_APR_ORACLE).getStrategyApr(
                collateralToken,
                collateralDelta
            );
    }

    function _getPtAprFromPrice(
        address ptToken,
        uint256 price
    ) internal view returns (uint256) {
        uint256 expiry = IPPrincipalToken(ptToken).expiry();
        if (block.timestamp >= expiry) return 0;

        uint256 timeToExpiry = expiry - block.timestamp;
        if (price == 0 || price >= WAD) return 0;

        uint256 gain = (WAD * WAD) / price - WAD;
        return (gain * SECONDS_PER_YEAR) / timeToExpiry;
    }

    function _applyPtPriceImpact(
        uint256 price,
        int256 collateralDeltaAsset,
        uint256 collateralValue,
        uint64 slippageBps
    ) internal pure returns (uint256) {
        if (
            price == 0 ||
            collateralValue == 0 ||
            slippageBps == 0 ||
            collateralDeltaAsset == 0
        ) return price;

        uint256 absDelta = uint256(
            collateralDeltaAsset > 0
                ? collateralDeltaAsset
                : -collateralDeltaAsset
        );
        uint256 impactBps = (absDelta * slippageBps) / collateralValue;
        if (impactBps > slippageBps) impactBps = slippageBps;

        if (collateralDeltaAsset > 0) {
            return price + (price * impactBps) / MAX_BPS;
        }

        return price - (price * impactBps) / MAX_BPS;
    }

    function _assetToCollateralDelta(
        address _strategy,
        int256 assetDelta
    ) internal view returns (int256) {
        (address morpho, Id marketId) = _getMorphoData(_strategy);
        MarketParams memory marketParams = IMorpho(morpho).idToMarketParams(
            marketId
        );
        uint256 price = IMorphoOracle(marketParams.oracle).price();
        return (assetDelta * int256(ORACLE_PRICE_SCALE)) / int256(price);
    }

    function _netApr(
        uint256 leverage,
        uint256 collateralApr,
        uint256 borrowApr
    ) internal pure returns (uint256) {
        if (leverage == 0) return 0;

        uint256 gross = (leverage * collateralApr) / WAD;
        uint256 cost = ((leverage - WAD) * borrowApr) / WAD;

        if (gross <= cost) return 0;

        return gross - cost;
    }

    function _getMorphoData(
        address _strategy
    ) internal view returns (address morpho, Id marketId) {
        morpho = IBaseMorphoLooper(_strategy).morpho();
        marketId = IBaseMorphoLooper(_strategy).marketId();
    }

    function _getPendleMarket(
        address _strategy
    ) internal view returns (bool isPt, address pendleMarket) {
        (bool success, bytes memory data) = _strategy.staticcall(
            abi.encodeWithSignature("pendleMarket()")
        );
        if (!success || data.length != 32) return (false, address(0));
        pendleMarket = abi.decode(data, (address));
        isPt = pendleMarket != address(0);
    }
}
