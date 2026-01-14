// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ICurveNG} from "./interfaces/ICurveNG.sol";
import {PTMorphoLooper, Id, SafeERC20, ERC20} from "./PTMorphoLooper.sol";

contract sUSDaiPTLooper is PTMorphoLooper {
    using SafeERC20 for ERC20;

    ICurveNG public constant CURVE_POOL =
        ICurveNG(0xa7CF5543a27BaDC3a74d51EA0A02E84799140E4E);

    int128 public constant USDC_INDEX = 1;
    int128 public constant sUSDai_INDEX = 0;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId,
        address _pendleMarket,
        address _pendleToken
    )
        PTMorphoLooper(
            _asset,
            _name,
            _collateralToken,
            _morpho,
            _marketId,
            _pendleMarket,
            _pendleToken
        )
    {
        ERC20(_pendleToken).forceApprove(
            address(CURVE_POOL),
            type(uint256).max
        );
        ERC20(_asset).forceApprove(address(CURVE_POOL), type(uint256).max);
    }

    /// @notice Convert USDC to sUSDai via Curve pool
    /// @dev Uses Curve NG pool to swap USDC -> sUSDai for Pendle PT operations.
    /// @param amount The amount of USDC to convert
    /// @return The amount of sUSDai received
    function _convertAssetToPendleToken(
        uint256 amount
    ) internal override returns (uint256) {
        return CURVE_POOL.exchange(USDC_INDEX, sUSDai_INDEX, amount, 0);
    }

    /// @notice Convert sUSDai back to USDC via Curve pool
    /// @dev Uses Curve NG pool to swap sUSDai -> USDC after PT operations.
    /// @param amount The amount of sUSDai to convert
    /// @return The amount of USDC received
    function _convertPendleTokenToAsset(
        uint256 amount
    ) internal override returns (uint256) {
        return CURVE_POOL.exchange(sUSDai_INDEX, USDC_INDEX, amount, 0);
    }
}
