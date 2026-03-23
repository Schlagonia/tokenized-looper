// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Maths} from "@periphery/libraries/Maths.sol";
import {ITaker} from "@periphery/interfaces/ITaker.sol";

import {ISwapAuction} from "../interfaces/ISwapAuction.sol";

/**
 * @title StrategySwapAuction
 * @notice Strategy-bound dutch auction used for leverage swaps.
 *         The strategy keeps custody. This contract only prices the swap and
 *         calls back into the strategy to settle it.
 */
contract StrategySwapAuction is ISwapAuction, ReentrancyGuard {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant AUCTION_LENGTH = 5 minutes;
    uint256 internal constant STEP_DURATION = 5 seconds;

    address public strategy;

    AuctionInfo internal currentAuction;

    event StrategySet(address indexed strategy);
    event AuctionKicked(
        address indexed from,
        address indexed want,
        uint256 amount,
        SwapDirection direction
    );
    event AuctionSettled(address indexed from);
    event AuctionTaken(
        address indexed from,
        address indexed taker,
        uint256 amountTaken,
        uint256 amountNeeded
    );

    modifier onlyStrategy() {
        require(msg.sender == strategy, "!strategy");
        _;
    }

    function auctionLength() external pure returns (uint256) {
        return AUCTION_LENGTH;
    }

    function activeAuction()
        external
        view
        returns (AuctionInfo memory)
    {
        return currentAuction;
    }

    function activeSellToken() external view returns (address) {
        return currentAuction.sellToken;
    }

    function activeBuyToken() external view returns (address) {
        return currentAuction.buyToken;
    }

    function activeDirection() external view returns (SwapDirection) {
        return currentAuction.direction;
    }

    function setStrategy(address _strategy) external {
        require(strategy == address(0), "!strategy");
        require(_strategy != address(0), "!strategy");

        strategy = _strategy;
        emit StrategySet(_strategy);
    }

    function isActive(address _from) public view returns (bool) {
        AuctionInfo memory auction = currentAuction;
        if (auction.sellToken != _from || auction.kicked == 0) return false;
        if (auction.amountRemaining == 0) return false;

        return _price(auction, block.timestamp) > 0;
    }

    function available(address _from) public view returns (uint256) {
        if (!isActive(_from)) return 0;
        return currentAuction.amountRemaining;
    }

    function price(address _from) external view returns (uint256) {
        return price(_from, block.timestamp);
    }

    function price(
        address _from,
        uint256 _timestamp
    ) public view returns (uint256) {
        AuctionInfo memory auction = currentAuction;
        if (auction.sellToken != _from || auction.kicked == 0) return 0;
        return _price(auction, _timestamp);
    }

    function getAmountNeeded(
        address _from,
        uint256 _amountToTake
    ) external view returns (uint256) {
        return getAmountNeeded(_from, _amountToTake, block.timestamp);
    }

    function getAmountNeeded(
        address _from,
        uint256 _amountToTake,
        uint256 _timestamp
    ) public view returns (uint256) {
        AuctionInfo memory auction = currentAuction;
        if (auction.sellToken != _from || auction.kicked == 0) return 0;

        return _getAmountNeeded(auction, _amountToTake, _timestamp);
    }

    function kick(
        address _from,
        address _want,
        uint256 _amount,
        SwapDirection _direction,
        uint256 _startingPrice,
        uint256 _minimumPrice,
        uint256 _stepDecayRate
    ) external onlyStrategy returns (uint256) {
        return
            _kick(
                _from,
                _want,
                _amount,
                _direction,
                _startingPrice,
                _minimumPrice,
                _stepDecayRate,
                false
            );
    }

    function forceKick(
        address _from,
        address _want,
        uint256 _amount,
        SwapDirection _direction,
        uint256 _startingPrice,
        uint256 _minimumPrice,
        uint256 _stepDecayRate
    ) external onlyStrategy returns (uint256) {
        return
            _kick(
                _from,
                _want,
                _amount,
                _direction,
                _startingPrice,
                _minimumPrice,
                _stepDecayRate,
                true
            );
    }

    function _kick(
        address _from,
        address _want,
        uint256 _amount,
        SwapDirection _direction,
        uint256 _startingPrice,
        uint256 _minimumPrice,
        uint256 _stepDecayRate,
        bool _force
    ) internal returns (uint256) {
        require(
            _from != address(0) &&
                _want != address(0) &&
                _from != _want &&
                _direction != SwapDirection.NONE,
            "bad token"
        );
        require(_amount != 0, "nothing to kick");
        require(_startingPrice >= _minimumPrice, "bad price");
        require(_minimumPrice != 0, "minimum price");
        require(_stepDecayRate > 0 && _stepDecayRate < 10_000, "bad decay");

        AuctionInfo memory auction = currentAuction;
        if (!_force && auction.sellToken != address(0)) {
            require(!isActive(auction.sellToken), "too soon");
        }

        uint256 sellDecimals = ERC20(_from).decimals();
        uint256 buyDecimals = ERC20(_want).decimals();
        require(sellDecimals <= 18 && buyDecimals <= 18, "bad decimals");

        currentAuction = AuctionInfo({
            sellToken: _from,
            buyToken: _want,
            sellTokenScaler: uint96(WAD / 10 ** sellDecimals),
            buyTokenScaler: uint96(WAD / 10 ** buyDecimals),
            kicked: uint64(block.timestamp),
            stepDuration: uint64(STEP_DURATION),
            stepDecayRate: uint64(_stepDecayRate),
            direction: _direction,
            amountRemaining: _amount,
            startingPrice: _startingPrice,
            minimumPrice: _minimumPrice
        });

        emit AuctionKicked(_from, _want, _amount, _direction);
        return _amount;
    }

    function settle(address _from) external onlyStrategy {
        AuctionInfo memory auction = currentAuction;
        require(auction.sellToken == _from && auction.kicked != 0, "!auction");
        require(!isActive(_from) || auction.amountRemaining == 0, "!settle");

        delete currentAuction;
        emit AuctionSettled(_from);
    }

    function take(address _from) external returns (uint256) {
        return _take(_from, type(uint256).max, msg.sender, new bytes(0));
    }

    function take(
        address _from,
        uint256 _maxAmount
    ) external returns (uint256) {
        return _take(_from, _maxAmount, msg.sender, new bytes(0));
    }

    function take(
        address _from,
        uint256 _maxAmount,
        address _takerReceiver
    ) external returns (uint256) {
        return _take(_from, _maxAmount, _takerReceiver, new bytes(0));
    }

    function take(
        address _from,
        uint256 _maxAmount,
        address _takerReceiver,
        bytes calldata _data
    ) external returns (uint256) {
        return _take(_from, _maxAmount, _takerReceiver, _data);
    }

    function _take(
        address _from,
        uint256 _maxAmount,
        address _takerReceiver,
        bytes memory _data
    ) internal nonReentrant returns (uint256 amountTaken) {
        require(_takerReceiver != address(0), "!receiver");

        AuctionInfo memory auction = currentAuction;
        require(auction.sellToken == _from && auction.kicked != 0, "!auction");

        uint256 availableAmount = available(_from);
        amountTaken = Maths.min(availableAmount, _maxAmount);

        uint256 needed = _getAmountNeeded(auction, amountTaken, block.timestamp);
        require(needed != 0, "zero needed");

        ITaker(strategy).auctionTakeCallback(
            _from,
            msg.sender,
            amountTaken,
            needed,
            abi.encode(_takerReceiver, _data)
        );

        if (amountTaken >= currentAuction.amountRemaining) {
            delete currentAuction;
            emit AuctionSettled(_from);
        } else {
            currentAuction.amountRemaining -= amountTaken;
        }

        emit AuctionTaken(_from, msg.sender, amountTaken, needed);
    }

    function _getAmountNeeded(
        AuctionInfo memory auction,
        uint256 _amountToTake,
        uint256 _timestamp
    ) internal pure returns (uint256) {
        if (_amountToTake == 0) return 0;

        uint256 currentPrice = _price(auction, _timestamp);
        if (currentPrice == 0) return 0;

        return
            (_amountToTake * auction.sellTokenScaler * currentPrice) /
            WAD /
            auction.buyTokenScaler;
    }

    function _price(
        AuctionInfo memory auction,
        uint256 _timestamp
    ) internal pure returns (uint256) {
        if (auction.kicked == 0 || auction.amountRemaining == 0) return 0;

        uint256 secondsElapsed = _timestamp > auction.kicked
            ? _timestamp - auction.kicked
            : 0;
        if (secondsElapsed > AUCTION_LENGTH) return 0;

        uint256 steps = secondsElapsed / auction.stepDuration;
        uint256 rayMultiplier = 1e27 - (uint256(auction.stepDecayRate) * 1e23);
        uint256 currentPrice = Maths.rmul(
            auction.startingPrice,
            Maths.rpow(rayMultiplier, steps)
        );

        return currentPrice < auction.minimumPrice ? 0 : currentPrice;
    }
}
