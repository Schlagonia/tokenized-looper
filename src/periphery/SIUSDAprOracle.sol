// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStakedToken} from "../interfaces/infinifi/IStakedToken.sol";
import {IYieldSharingV2} from "../interfaces/infinifi/IYieldSharingV2.sol";

contract SIUSDAprOracle {
    uint256 internal constant SECONDS_PER_YEAR = 31_556_952;

    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view returns (uint256) {
        address yieldSharing = IStakedToken(_strategy).yieldSharing();
        if (yieldSharing == address(0)) return 0;

        uint256 assets = IStakedToken(_strategy).totalAssets() +
            IYieldSharingV2(yieldSharing).vested();
        int256 assetsAfterInt = int256(assets) + _delta;
        if (assetsAfterInt <= 0) return 0;

        uint256 vesting = IYieldSharingV2(yieldSharing).vesting();
        if (vesting == 0) return 0;

        (
            uint32 lastAccrued,
            uint32 lastClaimed,
            uint208 rate
        ) = IYieldSharingV2(yieldSharing).point();

        uint256 maxTs = Math.max(uint256(lastAccrued), uint256(lastClaimed));
        if (block.timestamp <= maxTs || rate == 0) return 0;

        uint256 elapsed = block.timestamp - maxTs;
        uint256 ratePerSecond = uint256(rate);
        uint256 maxRate = vesting / elapsed;
        if (maxRate < ratePerSecond) ratePerSecond = maxRate;
        if (ratePerSecond == 0) return 0;

        uint256 annualRewards = ratePerSecond * SECONDS_PER_YEAR;
        return (annualRewards * 1e18) / uint256(assetsAfterInt);
    }
}
