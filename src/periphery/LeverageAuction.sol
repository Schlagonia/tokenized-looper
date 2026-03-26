// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Auction} from "@periphery/Auctions/Auction.sol";
import {IAuction} from "@periphery/interfaces/IAuction.sol";
import {ITaker} from "@periphery/interfaces/ITaker.sol";
import {Maths} from "@periphery/libraries/Maths.sol";

interface ILeverageAuctionStrategy is ITaker {}

interface ILeverageAuction is IAuction {
    function kick(
        address _from,
        uint256 _available,
        uint256 _startingPrice,
        uint256 _minimumPrice,
        uint256 _stepDecayRate
    ) external returns (uint256);
}

/**
 * @title LeverageAuction
 * @notice Thin periphery Auction wrapper for strategy leverage swaps.
 *         Keeps pricing logic and interface, replaces escrowed take settlement.
 */
contract LeverageAuction is Auction {
    uint256 internal constant LEVERAGE_AUCTION_STEP_DURATION = 5;

    address public immutable strategy;
    address public immutable fromToken;

    uint256 internal remaining;

    constructor(
        address _fromToken,
        address _want,
        address _strategy,
        address _governance
    ) {
        require(_fromToken != address(0), "!from");
        require(_want != address(0) && _want != _fromToken, "!want");
        require(_strategy != address(0), "!strategy");
        require(_governance != address(0), "!governance");

        strategy = _strategy;
        fromToken = _fromToken;

        initialize(_want, _strategy, _governance, 1);
        stepDuration = LEVERAGE_AUCTION_STEP_DURATION;
        emit UpdatedStepDuration(LEVERAGE_AUCTION_STEP_DURATION);

        uint256 decimals = ERC20(_fromToken).decimals();
        require(decimals <= 18, "unsupported decimals");

        auctions[_fromToken].scaler = uint64(WAD / 10 ** decimals);
        enabledAuctions.push(_fromToken);

        emit AuctionEnabled(_fromToken, _want);
    }

    function available(address _from) public view override returns (uint256) {
        if (_from != fromToken || !isActive(_from)) return 0;
        return remaining;
    }

    function kickable(address _from) external view override returns (uint256) {
        if (_from != fromToken || isActive(_from)) return 0;
        return ERC20(_from).balanceOf(strategy);
    }

    function _kick(
        address _from
    ) internal override returns (uint256 _available) {
        if (governanceOnlyKick) _checkGovernance();

        require(_from == fromToken, "not enabled");
        require(!isActive(_from), "too soon");
        _available = ERC20(_from).balanceOf(strategy);

        require(_available != 0, "nothing to kick");
        require(
            startingPrice >= minimumPrice && minimumPrice != 0,
            "bad price"
        );
        require(
            stepDecayRate > 0 && stepDecayRate < 10_000,
            "invalid decay rate"
        );

        auctions[_from].kicked = uint64(block.timestamp);
        auctions[_from].initialAvailable = uint128(_available);
        remaining = _available;

        emit AuctionKicked(_from, _available);
    }

    function kick(
        address _from,
        uint256 _available,
        uint256 _startingPrice,
        uint256 _minimumPrice,
        uint256 _stepDecayRate
    ) external nonReentrant returns (uint256) {
        if (governanceOnlyKick) _checkGovernance();

        require(_from == fromToken, "not enabled");
        require(!isActive(_from), "too soon");
        require(_available != 0, "nothing to kick");
        require(
            _startingPrice >= _minimumPrice && _minimumPrice != 0,
            "bad price"
        );
        require(
            _stepDecayRate > 0 && _stepDecayRate < 10_000,
            "invalid decay rate"
        );

        startingPrice = _startingPrice;
        minimumPrice = _minimumPrice;
        stepDecayRate = _stepDecayRate;
        auctions[_from].kicked = uint64(block.timestamp);
        auctions[_from].initialAvailable = uint128(_available);
        remaining = _available;

        emit UpdatedStartingPrice(_startingPrice);
        emit UpdatedMinimumPrice(_minimumPrice);
        emit UpdatedStepDecayRate(_stepDecayRate);
        emit AuctionKicked(_from, _available);

        return _available;
    }

    function settle(address _from) external override {
        require(_from == fromToken, "!auction");
        require(!isActive(_from) || remaining == 0, "!settle");

        auctions[_from].kicked = uint64(0);
        remaining = 0;

        emit AuctionSettled(_from);
    }

    function _take(
        address _from,
        uint256 _maxAmount,
        address _takerReceiver,
        bytes memory _data
    ) internal override nonReentrant returns (uint256 _amountTaken) {
        require(_from == fromToken, "not enabled");
        require(_takerReceiver != address(0), "!receiver");

        AuctionInfo memory auction = auctions[_from];

        uint256 _available = remaining;
        _amountTaken = Maths.min(_available, _maxAmount);

        uint256 needed = _getAmountNeeded(
            auction,
            _amountTaken,
            block.timestamp
        );
        require(needed != 0, "zero needed");

        ILeverageAuctionStrategy(strategy).auctionTakeCallback(
            _from,
            msg.sender,
            _amountTaken,
            needed,
            abi.encode(_takerReceiver, _data)
        );

        if (_amountTaken == _available) {
            auctions[_from].kicked = uint64(0);
            remaining = 0;

            emit AuctionSettled(_from);
        } else {
            remaining = _available - _amountTaken;
        }
    }

    function _price(
        uint256 _kicked,
        uint256 _available,
        uint256 _timestamp
    ) internal view override returns (uint256) {
        if (_available == 0) return 0;

        uint256 secondsElapsed = _timestamp - _kicked;
        if (secondsElapsed > auctionLength()) return 0;

        uint256 steps = secondsElapsed / stepDuration;
        uint256 rayMultiplier = 1e27 - (stepDecayRate * 1e23);
        uint256 decayMultiplier = Maths.rpow(rayMultiplier, steps);

        uint256 initialPrice = Maths.wdiv(
            startingPrice * wantInfo.scaler,
            _available
        );
        uint256 currentPrice = Maths.rmul(initialPrice, decayMultiplier);

        return currentPrice < minimumPrice ? 0 : currentPrice;
    }
}
