// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface ISwapAuction {
    enum SwapDirection {
        NONE,
        ASSET_TO_COLLATERAL,
        COLLATERAL_TO_ASSET
    }

    struct AuctionInfo {
        address sellToken;
        address buyToken;
        uint96 sellTokenScaler;
        uint96 buyTokenScaler;
        uint64 kicked;
        uint64 stepDuration;
        uint64 stepDecayRate;
        SwapDirection direction;
        uint256 amountRemaining;
        uint256 startingPrice;
        uint256 minimumPrice;
    }

    function strategy() external view returns (address);

    function activeAuction() external view returns (AuctionInfo memory);

    function activeSellToken() external view returns (address);

    function activeBuyToken() external view returns (address);

    function activeDirection() external view returns (SwapDirection);

    function auctionLength() external pure returns (uint256);

    function setStrategy(address _strategy) external;

    function isActive(address _from) external view returns (bool);

    function available(address _from) external view returns (uint256);

    function price(address _from) external view returns (uint256);

    function price(
        address _from,
        uint256 _timestamp
    ) external view returns (uint256);

    function getAmountNeeded(
        address _from,
        uint256 _amountToTake
    ) external view returns (uint256);

    function getAmountNeeded(
        address _from,
        uint256 _amountToTake,
        uint256 _timestamp
    ) external view returns (uint256);

    function kick(
        address _from,
        address _want,
        uint256 _amount,
        SwapDirection _direction,
        uint256 _startingPrice,
        uint256 _minimumPrice,
        uint256 _stepDecayRate
    ) external returns (uint256);

    function forceKick(
        address _from,
        address _want,
        uint256 _amount,
        SwapDirection _direction,
        uint256 _startingPrice,
        uint256 _minimumPrice,
        uint256 _stepDecayRate
    ) external returns (uint256);

    function settle(address _from) external;

    function take(address _from) external returns (uint256);

    function take(
        address _from,
        uint256 _maxAmount
    ) external returns (uint256);

    function take(
        address _from,
        uint256 _maxAmount,
        address _takerReceiver
    ) external returns (uint256);

    function take(
        address _from,
        uint256 _maxAmount,
        address _takerReceiver,
        bytes calldata _data
    ) external returns (uint256);
}
