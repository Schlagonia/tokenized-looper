// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {ITaker} from "@periphery/interfaces/ITaker.sol";
import {Maths} from "@periphery/libraries/Maths.sol";

/**
 * @title BaseLooper
 * @notice Shared leverage-looping logic using flashloans exclusively.
 *         Uses a fixed leverage ratio system with flashloan-based operations.
 *         Since asset == borrowToken, pricing uses a single oracle for collateral/asset conversion.
 *         Inheritors implement protocol specific hooks for flashloans, supplying collateral,
 *         borrowing, repaying, and oracle access.
 */
abstract contract BaseLooper is BaseHealthCheck {
    using SafeERC20 for ERC20;

    event AuctionKicked(address indexed from, uint256 available);
    event AuctionTaken(address indexed from, uint256 taken);

    /// @notice Accrue interest before state changing functions
    modifier accrue() {
        _accrueInterest();
        _;
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_SLIPPAGE = 100;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant AUCTION_STEP_DURATION = 60;
    uint256 internal constant AUCTION_LENGTH = 1 days;

    /// @notice Flashloan operation types
    enum FlashLoanOperation {
        DELEVERAGE, // Withdraw flow: decrease leverage
        AUCTION_LEVERAGE, // Auction take flow: sell asset for collateral
        AUCTION_DELEVERAGE // Auction take flow: sell collateral for asset
    }

    /// @notice Data passed through flashloan callback
    struct FlashLoanData {
        FlashLoanOperation operation;
        uint256 amount; // Amount to deploy or free (in asset terms)
        address sender;
        address receiver;
        uint256 amountOut;
        bytes swapData;
    }

    struct SwapInstruction {
        address target;
        bytes data;
    }

    struct AuctionState {
        uint64 kicked;
        uint64 stepDecayRate;
        uint128 initialAvailable;
        uint128 remaining;
        uint128 startingAmountOut;
        uint128 minimumAmountOut;
    }

    /// @notice Governance address allowed to update auction configuration.
    address public immutable GOVERNANCE;

    /// @notice Slippage tolerance (in basis points) for swaps.
    uint64 public slippage;

    /// @notice Dutch auction price decay per step in basis points.
    uint64 public stepDecayRate;

    mapping(address => AuctionState) public auctionStates;

    /// @notice Tracks the most recently kicked auction token to enforce single-auction activity.
    address internal activeAuctionToken;

    /// @notice The timestamp of the last tend.
    uint256 public lastTend;

    /// @notice The amount to discount collateral by in reports in basis points.
    uint256 public reportBuffer;

    /// @notice The minimum interval between tends.
    uint256 public minTendInterval;

    /// @notice The maximum amount of asset that can be deposited
    uint256 public depositLimit;

    /// @notice Maximum amount of asset to swap in a single tend
    uint256 public maxAmountToSwap;

    /// @notice Buffer tolerance in WAD (e.g., 0.5e18 = +/- 0.5x triggers tend)
    /// @dev Bounds are [targetLeverageRatio - buffer, targetLeverageRatio + buffer]
    uint256 public leverageBuffer;

    /// @notice Maximum leverage ratio in WAD (e.g., 10e18 = 10x leverage)
    /// Will trigger a tend if the current leverage ratio exceeds this value.
    uint256 public maxLeverageRatio;

    /// @notice Target leverage ratio in WAD (e.g., 3e18 = 3x leverage)
    /// @dev leverage = collateralValue / (collateralValue - debtValue) = 1 / (1 - LTV)
    uint256 public targetLeverageRatio;

    /// The max the base fee (in gwei) will be for a tend.
    uint256 public maxGasPriceToTend;

    /// Lower limit on flashloan size.
    uint256 public minAmountToBorrow;

    /// The token posted as collateral in the loop.
    address public immutable collateralToken;

    bytes internal _forcedExitSwapData;

    mapping(address => bool) public allowed;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _governance
    ) BaseHealthCheck(_asset, _name) {
        require(_governance != address(0), "!gov");
        collateralToken = _collateralToken;
        GOVERNANCE = _governance;

        depositLimit = type(uint256).max;
        // Allow self so we can use availableDepositLimit() to get the max deposit amount.
        allowed[address(this)] = true;

        // Leverage ratio defaults: 3x target, 0.5x buffer
        targetLeverageRatio = 3e18;
        leverageBuffer = 0.25e18;
        maxLeverageRatio = 4e18;

        minTendInterval = 2 hours;
        maxAmountToSwap = type(uint256).max;
        maxGasPriceToTend = 50 * 1e9;
        slippage = 10;
        stepDecayRate = 1;

        _setLossLimitRatio(10);
        _setProfitLimitRatio(500);
    }

    function version() public pure virtual returns (string memory) {
        return "1.1.0";
    }

    /*//////////////////////////////////////////////////////////////
                            SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the maximum total assets the strategy can accept.
    /// @dev This gates new deposits via `availableDepositLimit`; it does not force an unwind if current assets already exceed the new cap.
    /// @param _depositLimit New deposit limit in asset units.
    function setDepositLimit(uint256 _depositLimit) external onlyManagement {
        depositLimit = _depositLimit;
    }

    /// @notice Allow or disallow an address for privileged strategy interactions.
    /// @dev `availableDepositLimit` returns 0 for addresses not allowlisted, so disabling an address blocks fresh deposits from that caller.
    /// @param _address Address to update.
    /// @param _allowed Whether the address is allowed.
    function setAllowed(
        address _address,
        bool _allowed
    ) external onlyManagement {
        allowed[_address] = _allowed;
    }

    /// @notice Configure leverage targeting and safety bounds.
    /// @dev Setting target to 0 disables leverage targeting and requires buffer = 0;
    ///     max leverage is also constrained below protocol liquidation threshold.
    /// @param _targetLeverageRatio Target leverage ratio in WAD (1e18 = 1x).
    /// @param _leverageBuffer Allowed deviation from target leverage in WAD.
    /// @param _maxLeverageRatio Hard max leverage ratio in WAD.
    function setLeverageParams(
        uint256 _targetLeverageRatio,
        uint256 _leverageBuffer,
        uint256 _maxLeverageRatio
    ) external onlyManagement {
        _setLeverageParams(
            _targetLeverageRatio,
            _leverageBuffer,
            _maxLeverageRatio
        );
    }

    function _setLeverageParams(
        uint256 _targetLeverageRatio,
        uint256 _leverageBuffer,
        uint256 _maxLeverageRatio
    ) internal virtual {
        if (_targetLeverageRatio == 0) {
            require(_leverageBuffer == 0, "buf0");
        } else {
            require(_targetLeverageRatio >= WAD, "lev<1");
            require(_leverageBuffer >= 0.01e18, "buf");
            require(_targetLeverageRatio > _leverageBuffer, "t<b");
        }

        require(
            _maxLeverageRatio >= _targetLeverageRatio + _leverageBuffer,
            "max"
        );

        // Ensure max leverage doesn't exceed LLTV
        uint256 maxLTV = WAD - (WAD * WAD) / _maxLeverageRatio;
        require(maxLTV < getLiquidateCollateralFactor(), "lltv");

        targetLeverageRatio = _targetLeverageRatio;
        leverageBuffer = _leverageBuffer;
        maxLeverageRatio = _maxLeverageRatio;
    }

    /// @notice Set the maximum base fee accepted for keeper tending.
    /// @dev This only affects `_tendTrigger` keepers; it does not block management/emergency operations.
    /// @param _maxGasPriceToTend Max acceptable `block.basefee`.
    function setMaxGasPriceToTend(
        uint256 _maxGasPriceToTend
    ) external onlyManagement {
        maxGasPriceToTend = _maxGasPriceToTend;
    }

    /// @notice Set swap slippage tolerance used for min amount out checks.
    /// @dev Applied to both asset->collateral and collateral->asset swaps; value is in BPS and must be strictly less than `MAX_BPS`.
    ///      If the strategy is not shutdown, the slippage must be strictly less than `MAX_SLIPPAGE`.
    /// @param _slippage Slippage in basis points.
    function setSlippage(uint256 _slippage) external onlyManagement {
        require(_slippage < MAX_BPS, "slip");
        if (!TokenizedStrategy.isShutdown())
            require(_slippage < MAX_SLIPPAGE, "slip-hi");
        slippage = uint64(_slippage);
    }

    function setstepDecayRate(
        uint256 _stepDecayRate
    ) external onlyManagement {
        require(
            _stepDecayRate > 0 && _stepDecayRate < 10_000,
            "dec"
        );
        require(!_hasActiveLeverageAuction(), "active");
        stepDecayRate = uint64(_stepDecayRate);
    }

    /// @notice Set the report buffer used when accounting for assets.
    /// @dev `estimatedTotalAssets` discounts collateral value by this BPS amount,
    ///       so increasing it makes reported assets more conservative.
    /// @param _reportBuffer Buffer in basis points.
    function setReportBuffer(uint256 _reportBuffer) external onlyManagement {
        require(_reportBuffer < MAX_BPS, "buf");
        reportBuffer = _reportBuffer;
    }

    /// @notice Set the minimum debt amount required to execute borrow/deleverage ops.
    /// @dev If set too high, small rebalance operations are skipped and leverage can drift until a larger adjustment is possible.
    /// @param _minAmountToBorrow Minimum amount in asset units.
    function setMinAmountToBorrow(
        uint256 _minAmountToBorrow
    ) external onlyManagement {
        minAmountToBorrow = _minAmountToBorrow;
    }

    /// @notice Set the minimum interval between automated tend operations.
    /// @dev This throttles routine keeper tending after checks pass;
    ///     it does not bypass hard risk checks like liquidation/max leverage triggers.
    /// @param _minTendInterval Minimum delay in seconds.
    function setMinTendInterval(
        uint256 _minTendInterval
    ) external onlyManagement {
        minTendInterval = _minTendInterval;
    }

    /// @notice Set the max asset amount that can be swapped in one rebalance path.
    /// @dev Caps `_amount + flashloanAmount` during lever-up;
    ///      lower values reduce execution size but can leave idle assets and under-target leverage.
    /// @param _maxAmountToSwap Maximum swap amount in asset units.
    function setMaxAmountToSwap(
        uint256 _maxAmountToSwap
    ) external onlyManagement {
        maxAmountToSwap = _maxAmountToSwap;
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy funds into the leveraged position
    /// @dev Override to customize deployment behavior. Default is no-op (funds deployed via _harvestAndReport).
    ///      Called by TokenizedStrategy when deposits are made.
    /// @param _amount The amount of asset to deploy
    function _deployFunds(uint256 _amount) internal virtual override accrue {}

    /// @notice Free funds from the leveraged position for withdrawal
    /// @dev Override to customize withdrawal behavior. Default deleverages the position.
    ///      Called by TokenizedStrategy when withdrawals are requested.
    /// @param _amount The amount of asset to free
    function _freeFunds(uint256 _amount) internal virtual override accrue {
        _withdrawFunds(_amount);
    }

    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner,
        bytes calldata _swapData
    ) external returns (uint256 _shares) {
        _setForcedExitSwapData(_swapData);
        bytes memory result = _delegateCall(
            abi.encodeCall(
                ITokenizedStrategy.withdraw,
                (_assets, _receiver, _owner, 0)
            )
        );
        _clearForcedExitSwapData();
        return abi.decode(result, (uint256));
    }

    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner,
        bytes calldata _swapData
    ) external returns (uint256 _assets) {
        _setForcedExitSwapData(_swapData);
        bytes memory result = _delegateCall(
            abi.encodeCall(
                ITokenizedStrategy.redeem,
                (_shares, _receiver, _owner, 0)
            )
        );
        _clearForcedExitSwapData();
        return abi.decode(result, (uint256));
    }

    /// @notice Harvest rewards and report total assets
    /// @dev Override to customize harvesting behavior. Default claims rewards, only delevers when above
    ///      `maxLeverageRatio`, and reports total assets. Called during strategy reports.
    /// @return _totalAssets The total assets held by the strategy
    function _harvestAndReport()
        internal
        virtual
        override
        accrue
        returns (uint256 _totalAssets)
    {
        _claimAndSellRewards();
        if (getCurrentLeverageRatio() > maxLeverageRatio) {
            _lever(balanceOfAsset());
        }

        _totalAssets = estimatedTotalAssets();
    }

    /// @notice Calculate the estimated total assets of the strategy
    /// @dev Override to customize asset calculation. Default returns loose assets + collateral value - debt.
    /// @return The estimated total assets in asset token terms
    function estimatedTotalAssets() public view virtual returns (uint256) {
        // Collateral value discounted by the report buffer.
        uint256 collateralValue = (_collateralToAsset(
            balanceOfCollateral() + balanceOfCollateralToken()
        ) * (MAX_BPS - reportBuffer)) / MAX_BPS;

        return balanceOfAsset() + collateralValue - balanceOfDebt();
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate the maximum amount that can be deposited by an address
    /// @dev Override to customize deposit limits. Default checks allowlist, pause states,
    ///      deposit limit, collateral capacity, and borrow capacity.
    /// @param _owner The address attempting to deposit
    /// @return The maximum amount that can be deposited
    function availableDepositLimit(
        address _owner
    ) public view virtual override returns (uint256) {
        if (!allowed[_owner]) return 0;

        if (_isSupplyPaused() || _isBorrowPaused()) return 0;

        if (targetLeverageRatio < WAD) return 0;

        uint256 _depositLimit = depositLimit;
        if (_depositLimit == type(uint256).max) {
            return type(uint256).max;
        }

        uint256 totalAssets = TokenizedStrategy.totalAssets();
        return _depositLimit > totalAssets ? _depositLimit - totalAssets : 0;
    }

    /// @notice Calculate the maximum amount that can be withdrawn by an address
    /// @dev Override to customize withdraw limits. Default returns max uint256 if flashloan covers debt,
    ///      otherwise calculates based on flashloan availability and target leverage.
    ///      The owner parameter is unused in default implementation.
    /// @return The maximum amount that can be withdrawn
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view virtual override returns (uint256) {
        uint256 currentDebt = balanceOfDebt();
        uint256 flashloanAvailable = maxFlashloan();

        if (flashloanAvailable >= currentDebt) return type(uint256).max;

        // If target leverage ratio is 1 or 0 and we cant repay the debt, we cant withdraw yet.
        if (targetLeverageRatio <= WAD) return 0;

        // Limited by flashloan: calculate max withdrawable
        // When debtToRepay is capped at maxFlashloan:
        //   targetDebt = currentDebt - maxFlashloan
        //   targetEquity = targetDebt * WAD / (L - WAD)
        //   maxWithdraw = currentEquity - targetEquity
        uint256 targetDebt = currentDebt - flashloanAvailable;
        uint256 targetEquity = (targetDebt * WAD) / (targetLeverageRatio - WAD);

        (uint256 collateralValue, ) = position();
        uint256 currentEquity = collateralValue - currentDebt;

        return currentEquity > targetEquity ? currentEquity - targetEquity : 0;
    }

    /// @notice Rebalance the position to maintain target leverage
    /// @dev Override to customize rebalancing behavior. Default levers up with idle assets and updates lastTend.
    ///      Called by keepers when _tendTrigger returns true.
    /// @param _totalIdle The total idle assets available for deployment
    function _tend(uint256 _totalIdle) internal virtual override accrue {
        _lever(_totalIdle);
    }

    /// @notice Check if the position needs rebalancing
    /// @dev Override to customize tend trigger logic. Default checks liquidation risk, leverage bounds,
    ///      idle assets, min tend interval, and gas price.
    /// @return True if a tend operation should be triggered
    function _tendTrigger() internal view virtual override returns (bool) {
        if (_isLiquidatable()) return true;
        if (TokenizedStrategy.totalAssets() == 0) return false;
        if (_isSupplyPaused() || _isBorrowPaused()) return false;
        if (_hasActiveLeverageAuction()) return false;

        uint256 currentLeverage = getCurrentLeverageRatio();

        if (currentLeverage > maxLeverageRatio) {
            return true;
        }

        if (block.timestamp - lastTend < minTendInterval) {
            return false;
        }

        uint256 _targetLeverageRatio = targetLeverageRatio;
        if (_targetLeverageRatio == 0) {
            return currentLeverage > 0 && _isBaseFeeAcceptable();
        }

        // If we are over the upper bound
        if (currentLeverage > _targetLeverageRatio + leverageBuffer) {
            uint256 _minAmountToBorrow = minAmountToBorrow;
            // Over-leveraged: can repay with idle assets OR delever via flashloan
            if (
                balanceOfAsset() > _minAmountToBorrow ||
                maxFlashloan() > _minAmountToBorrow
            ) {
                return _isBaseFeeAcceptable();
            }
            return false;
        }

        // We don't auto tend when under the lower bound
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                        FLASHLOAN OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adjust position to target leverage ratio
    /// @dev Handles three cases: lever up, delever, or just deploy _amount
    function _lever(uint256 _amount) internal virtual {
        (uint256 currentCollateralValue, uint256 currentDebt) = position();
        uint256 currentEquity = currentCollateralValue - currentDebt + _amount;
        (, uint256 targetDebt) = getTargetPosition(currentEquity);

        if (targetDebt >= currentDebt) {
            uint256 flashloanAmount = Math.min(
                targetDebt - currentDebt,
                maxFlashloan()
            );

            uint256 maxCollateralInAsset = _collateralToAsset(
                _maxCollateralDeposit()
            );
            uint256 maxSwap = maxCollateralInAsset == type(uint256).max
                ? maxAmountToSwap
                : Math.min(
                    maxAmountToSwap,
                    (maxCollateralInAsset * (MAX_BPS - slippage)) / MAX_BPS
                );

            uint256 totalSwap = _amount + flashloanAmount;
            if (maxSwap != type(uint256).max && totalSwap > maxSwap) {
                totalSwap = maxSwap;
            }

            _kickAuction(address(asset), collateralToken, totalSwap);
            return;
        }

        if (currentDebt > targetDebt) {
            uint256 debtToRepay = currentDebt - targetDebt;

            if (_amount >= debtToRepay) {
                _repay(debtToRepay);
                _amount -= debtToRepay;
                if (_amount > 0) {
                    _kickAuction(address(asset), collateralToken, _amount);
                }
                return;
            }

            _repay(_amount);
            debtToRepay -= _amount;
            debtToRepay = Math.min(debtToRepay, maxFlashloan());

            if (maxAmountToSwap != type(uint256).max) {
                debtToRepay = Math.min(debtToRepay, maxAmountToSwap);
            }

            if (debtToRepay == 0) return;

            uint256 collateralToWithdraw = (_assetToCollateral(debtToRepay) *
                (MAX_BPS + slippage)) / MAX_BPS;
            _kickAuction(collateralToken, address(asset), collateralToWithdraw);
            return;
        }
    }

    /// @notice Will withdraw funds from the strategy to cover the amount needed keeping the position at target leverage ratio using a flashloan
    function _withdrawFunds(uint256 _amountNeeded) internal virtual {
        (uint256 valueOfCollateral, uint256 currentDebt) = position();
        uint256 equity = valueOfCollateral - currentDebt;

        uint256 targetEquity = equity > _amountNeeded
            ? equity - _amountNeeded
            : 0;
        (, uint256 targetDebt) = getTargetPosition(targetEquity);

        if (currentDebt == 0 || targetDebt > currentDebt) {
            // No debt, just withdraw collateral
            uint256 toWithdraw = _assetToCollateral(_amountNeeded);
            _withdrawCollateral(Math.min(toWithdraw, balanceOfCollateral()));

            toWithdraw = Math.min(toWithdraw, balanceOfCollateralToken());
            _executeSwap(
                collateralToken,
                address(asset),
                toWithdraw,
                _getAmountOut(toWithdraw, false),
                _forcedExitSwapData
            );
            return;
        }

        uint256 debtToRepay = currentDebt - targetDebt;

        // Cap flashloan by available liquidity
        debtToRepay = Math.min(debtToRepay, maxFlashloan());

        if (debtToRepay == 0) return;

        uint256 collateralToWithdraw = debtToRepay == currentDebt
            ? balanceOfCollateral()
            : _assetToCollateral(debtToRepay + _amountNeeded);

        bytes memory data = abi.encode(
            FlashLoanData({
                operation: FlashLoanOperation.DELEVERAGE,
                amount: collateralToWithdraw,
                sender: address(0),
                receiver: address(0),
                amountOut: 0,
                swapData: _forcedExitSwapData
            })
        );

        _executeFlashloan(address(asset), debtToRepay, data);
    }

    /// @notice Called by protocol-specific flashloan callback
    function _onFlashloanReceived(
        uint256 assets,
        bytes memory data
    ) internal virtual {
        FlashLoanData memory params = abi.decode(data, (FlashLoanData));

        if (params.operation == FlashLoanOperation.AUCTION_LEVERAGE) {
            _settleAuctionLeverageTake(assets, params);
            return;
        } else if (params.operation == FlashLoanOperation.AUCTION_DELEVERAGE) {
            _settleAuctionDeleverageTake(assets, params);
            return;
        } else if (params.operation == FlashLoanOperation.DELEVERAGE) {
            _executeDeleverageCallback(assets, params);
            return;
        }
        revert("op");
    }

    function _settleAuctionLeverageTake(
        uint256 assets,
        FlashLoanData memory params
    ) internal virtual {
        _executeAuctionCallback(
            address(asset),
            collateralToken,
            params.amount,
            params.sender,
            params.receiver,
            params.amountOut,
            params.swapData
        );

        _supplyCollateral(params.amountOut);
        _borrow(assets);

        require(
            getCurrentLeverageRatio() < targetLeverageRatio + leverageBuffer,
            "lev"
        );
    }

    function _settleAuctionDeleverageTake(
        uint256 assets,
        FlashLoanData memory params
    ) internal virtual {
        uint256 initialLeverage = getCurrentLeverageRatio();

        _executeAuctionCallback(
            collateralToken,
            address(asset),
            params.amount,
            params.sender,
            params.receiver,
            params.amountOut,
            params.swapData
        );

        _repay(Math.min(params.amountOut, balanceOfDebt()));
        _withdrawCollateral(assets);

        uint256 finalLeverage = getCurrentLeverageRatio();
        require(
            finalLeverage < maxLeverageRatio || finalLeverage < initialLeverage,
            "lev"
        );
    }

    function _executeDeleverageCallback(
        uint256 flashloanAmount,
        FlashLoanData memory params
    ) internal virtual {
        uint256 initialLeverage = getCurrentLeverageRatio();

        // Use flashloaned amount to repay debt
        _repay(Math.min(flashloanAmount, balanceOfDebt()));

        uint256 collateralToWithdraw = Math.min(
            params.amount,
            balanceOfCollateral()
        );
        // Withdraw
        _withdrawCollateral(collateralToWithdraw);

        // Convert collateral back to asset
        _executeSwap(
            collateralToken,
            address(asset),
            collateralToWithdraw,
            _getAmountOut(collateralToWithdraw, false),
            params.swapData
        );

        // Sanity check
        uint256 finalLeverage = getCurrentLeverageRatio();
        // Make sure the leverage is within the bounds, or at least improved.
        require(
            finalLeverage < maxLeverageRatio || finalLeverage < initialLeverage,
            "lev"
        );
    }

    function _executeAuctionCallback(
        address _from,
        address _want,
        uint256 _amountTaken,
        address _sender,
        address _receiver,
        uint256 _amountNeeded,
        bytes memory _data
    ) internal virtual {
        ERC20(_from).safeTransfer(_receiver, _amountTaken);
        if (_data.length != 0) {
            ITaker(_receiver).auctionTakeCallback(
                _from,
                _sender,
                _amountTaken,
                _amountNeeded,
                _data
            );
        }

        ERC20(_want).safeTransferFrom(_sender, address(this), _amountNeeded);
    }

    /*//////////////////////////////////////////////////////////////
                            AUCTIONS
    //////////////////////////////////////////////////////////////*/

    function want() public view returns (address) {
        return want(activeAuctionToken);
    }

    function want(address _from) public view returns (address) {
        if (_from == address(asset)) return collateralToken;
        return address(asset);
    }

    function kicked(address _from) public view returns (uint256) {
        return auctionStates[_from].kicked;
    }

    function available(address _from) public view returns (uint256) {
        if (!isActive(_from)) return 0;
        return auctionStates[_from].remaining;
    }

    function isActive(address _from) public view returns (bool) {
        return _isAuctionActive(auctionStates[_from], block.timestamp);
    }

    function activeAuction() public view returns (address) {
        address from = activeAuctionToken;
        if (from == address(0) || !isActive(from)) return address(0);
        return from;
    }

    function price(address _from) public view returns (uint256) {
        AuctionState storage auction = auctionStates[_from];
        uint256 amountOut = _getAuctionAmountOut(auction, block.timestamp);
        if (amountOut == 0 || auction.initialAvailable == 0) return 0;

        return
            Math.mulDiv(
                10 ** ERC20(_from).decimals(),
                amountOut,
                auction.initialAvailable
            );
    }

    function getAmountNeeded(
        address _from,
        uint256 _amountToTake
    ) external view returns (uint256) {
        if (_amountToTake == 0) return 0;
        return _getAmountNeeded(_from, _amountToTake, block.timestamp);
    }

    function take(
        address _from,
        uint256 _maxAmount,
        address _takerReceiver,
        bytes calldata _data
    ) external accrue returns (uint256 amountTaken) {
        AuctionState storage auction = auctionStates[_from];
        address wantToken = want(_from);
        amountTaken = Math.min(auction.remaining, _maxAmount);

        uint256 amountNeeded = _getAmountNeeded(
            _from,
            amountTaken,
            block.timestamp
        );
        require(amountNeeded != 0, "need0");

        if(_from == address(asset) || _from == collateralToken) {
            uint256 currentBalance = ERC20(_from).balanceOf(address(this));

            FlashLoanData memory params = FlashLoanData({
                operation: _from == address(asset)
                    ? FlashLoanOperation.AUCTION_LEVERAGE
                    : FlashLoanOperation.AUCTION_DELEVERAGE,
                amount: amountTaken,
                sender: msg.sender,
                receiver: _takerReceiver,
                amountOut: amountNeeded,
                swapData: _data
            });

            // If we don't have enough balance, we need to flashloan the difference.
            if (currentBalance < amountTaken) {
                _executeFlashloan(
                    _from,
                    amountTaken - currentBalance,
                    abi.encode(params)
                );

            // Else just settle the auciton
            } else if (_from == address(asset)) {
                    _settleAuctionLeverageTake(0, params);
            } else if (_from == collateralToken) {
                    _settleAuctionDeleverageTake(0, params);
            }
        } else {
            _executeAuctionCallback(
                _from,
                wantToken,
                amountTaken,
                msg.sender,
                _takerReceiver,
                amountNeeded,
                _data
            );
        }

        if (amountTaken == auction.remaining) {
            _clearAuctionState(_from);
        } else {
            auction.remaining = uint128(auction.remaining - amountTaken);
        }

        emit AuctionTaken(_from, amountTaken);
    }

    function _kickAuction(
        address _from,
        address _want,
        uint256 _amount
    ) internal virtual returns (bool) {
        if (_amount == 0) return false;
        require(!_hasActiveLeverageAuction(), "active");
        require(_want == want(_from), "!want");

        (
            uint256 startingAmountOut,
            uint256 minimumAmountOut,
            uint256 configuredStepDecayRate
        ) = _getAuctionKickConfig(_from, _want, _amount);
        require(
            startingAmountOut >= minimumAmountOut && startingAmountOut != 0,
            "auc"
        );

        AuctionState memory auction = AuctionState({
            kicked: uint64(block.timestamp),
            stepDecayRate: uint64(configuredStepDecayRate),
            initialAvailable: uint128(_amount),
            remaining: uint128(_amount),
            startingAmountOut: uint128(startingAmountOut),
            minimumAmountOut: uint128(minimumAmountOut)
        });

        auctionStates[_from] = auction;
        activeAuctionToken = _from;

        lastTend = block.timestamp;
        emit AuctionKicked(_from, _amount);
        return true;
    }

    function _hasActiveLeverageAuction() internal view returns (bool) {
        return activeAuction() != address(0);
    }

    function _getAmountNeeded(
        address _from,
        uint256 _amountToTake,
        uint256 _timestamp
    ) internal view returns (uint256) {
        if (_amountToTake == 0) return 0;

        AuctionState storage auction = auctionStates[_from];
        uint256 amountOut = _getAuctionAmountOut(auction, _timestamp);
        if (amountOut == 0 || auction.initialAvailable == 0) return 0;

        return Math.mulDiv(_amountToTake, amountOut, auction.initialAvailable);
    }

    function _getAuctionKickConfig(
        address _from,
        address _want,
        uint256 _amount
    )
        internal
        view
        returns (
            uint256 _startingAmountOut,
            uint256 _minimumAmountOut,
            uint256 _stepDecayRate
        )
    {
        if (_from != address(asset) && _from != collateralToken) {
            _startingAmountOut = 1_000_000 * (10 ** ERC20(_want).decimals());
            _minimumAmountOut = 1;
            _stepDecayRate = 50;
            return (_startingAmountOut, _minimumAmountOut, _stepDecayRate);
        }

        uint256 quotedAmountOut = _from == address(asset)
            ? _assetToCollateral(_amount)
            : _collateralToAsset(_amount);

        _startingAmountOut =
            (quotedAmountOut * (MAX_BPS + slippage)) /
            MAX_BPS;
        _minimumAmountOut = (quotedAmountOut * (MAX_BPS - slippage)) / MAX_BPS;
        _stepDecayRate = stepDecayRate;
    }

    function _isAuctionActive(
        AuctionState storage auction,
        uint256 _timestamp
    ) internal view returns (bool) {
        return _getAuctionAmountOut(auction, _timestamp) != 0;
    }

    function _getAuctionAmountOut(
        AuctionState storage auction,
        uint256 _timestamp
    ) internal view returns (uint256) {
        if (
            auction.kicked == 0 ||
            auction.initialAvailable == 0 ||
            auction.remaining == 0 ||
            _timestamp < auction.kicked
        ) return 0;

        uint256 secondsElapsed = _timestamp - auction.kicked;
        if (secondsElapsed > AUCTION_LENGTH) return 0;

        uint256 steps = secondsElapsed / AUCTION_STEP_DURATION;
        uint256 rayMultiplier = 1e27 - (uint256(auction.stepDecayRate) * 1e23);
        uint256 decayMultiplier = Maths.rpow(rayMultiplier, steps);
        uint256 currentAmountOut = Maths.rmul(
            auction.startingAmountOut,
            decayMultiplier
        );

        return
            currentAmountOut < auction.minimumAmountOut ? 0 : currentAmountOut;
    }

    function _clearAuctionState(address _from) internal {
        delete auctionStates[_from];
        if (activeAuctionToken == _from) activeAuctionToken = address(0);
    }

    function _executeSwap(
        address _from,
        address _to,
        uint256 _amount,
        uint256 _amountOutMin,
        bytes memory _swapData
    ) internal virtual returns (uint256 amountOut) {
        if (_amount == 0) return 0;
        require(_swapData.length != 0, "!swapData");

        SwapInstruction memory instruction = abi.decode(
            _swapData,
            (SwapInstruction)
        );
        require(!_isUnsafeSwapSelector(instruction.data), "!selector");

        ERC20 fromToken = ERC20(_from);
        uint256 balanceBefore = ERC20(_to).balanceOf(address(this));

        fromToken.forceApprove(instruction.target, _amount);

        (bool success, ) = instruction.target.call(instruction.data);

        fromToken.forceApprove(instruction.target, 0);
        require(success, "!swapData");

        amountOut = ERC20(_to).balanceOf(address(this)) - balanceBefore;
        require(amountOut >= _amountOutMin, "!amountOut");
    }

    function _isUnsafeSwapSelector(
        bytes memory _data
    ) internal pure returns (bool) {
        if (_data.length < 4) return false;

        bytes4 selector = bytes4(_data);

        return
            selector == ERC20.approve.selector ||
            selector == ERC20.increaseAllowance.selector;
    }

    function _setForcedExitSwapData(bytes calldata _swapData) internal {
        delete _forcedExitSwapData;
        _forcedExitSwapData = _swapData;
    }

    function _clearForcedExitSwapData() internal {
        delete _forcedExitSwapData;
    }

    /*//////////////////////////////////////////////////////////////
                    ABSTRACT - PROTOCOL SPECIFIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Accrue interest before state changing functions
    function _accrueInterest() internal virtual {
        // No-op by default
    }

    /// @notice Execute a flashloan through the protocol
    function _executeFlashloan(
        address token,
        uint256 amount,
        bytes memory data
    ) internal virtual;

    /// @notice Max available flashloan from protocol
    function maxFlashloan() public view virtual returns (uint256);

    /// @notice Get oracle price (loan token value per 1 collateral token, ORACLE_PRICE_SCALE)
    /// @dev Must return raw oracle price in 1e36 scale for precision in conversions
    function _getCollateralPrice() internal view virtual returns (uint256);

    /// @notice Supply collateral (with asset->collateral conversion)
    function _supplyCollateral(uint256 amount) internal virtual;

    /// @notice Withdraw collateral (with collateral->asset conversion)
    /// @dev Must implement protocol-specific collateral withdrawal logic.
    /// @param amount The amount of collateral to withdraw
    function _withdrawCollateral(uint256 amount) internal virtual;

    /// @notice Borrow assets from the lending protocol
    /// @dev Must implement protocol-specific borrow logic.
    /// @param amount The amount of asset to borrow
    function _borrow(uint256 amount) internal virtual;

    /// @notice Repay borrowed assets to the lending protocol
    /// @dev Must implement protocol-specific repay logic. Should handle partial repayments gracefully.
    /// @param amount The amount of asset to repay
    function _repay(uint256 amount) internal virtual;

    /// @notice Check if collateral supply is paused on the lending protocol
    /// @dev Must implement protocol-specific pause check.
    /// @return True if supplying collateral is currently paused
    function _isSupplyPaused() internal view virtual returns (bool);

    /// @notice Check if borrowing is paused on the lending protocol
    /// @dev Must implement protocol-specific pause check.
    /// @return True if borrowing is currently paused
    function _isBorrowPaused() internal view virtual returns (bool);

    /// @notice Check if the position is at risk of liquidation
    /// @dev Must implement protocol-specific liquidation check. Used by _tendTrigger for emergency rebalancing.
    /// @return True if the position can be liquidated
    function _isLiquidatable() internal view virtual returns (bool);

    /// @notice Get the maximum amount of collateral that can be deposited
    /// @dev Must implement protocol-specific capacity check. Return type(uint256).max if unlimited.
    /// @return The maximum collateral amount that can be deposited
    function _maxCollateralDeposit() internal view virtual returns (uint256);

    /// @notice Get the maximum amount that can be borrowed
    /// @dev Must implement protocol-specific borrow capacity check.
    /// @return The maximum amount that can be borrowed in asset terms
    function _maxBorrowAmount() internal view virtual returns (uint256);

    /// @notice Get the liquidation loan-to-value threshold (LLTV)
    /// @dev Must implement protocol-specific LLTV retrieval. Used to validate leverage params.
    /// @return The liquidation threshold in WAD (e.g., 0.9e18 = 90% LLTV)
    function getLiquidateCollateralFactor()
        public
        view
        virtual
        returns (uint256);

    /// @notice Get the current collateral balance in the lending protocol
    /// @dev Must implement protocol-specific collateral balance retrieval.
    /// @return The amount of collateral supplied to the protocol
    function balanceOfCollateral() public view virtual returns (uint256);

    /// @notice Get the current debt balance owed to the lending protocol
    /// @dev Must implement protocol-specific debt balance retrieval.
    /// @return The amount of debt owed in asset terms
    function balanceOfDebt() public view virtual returns (uint256);

    /// @notice Claim and sell any protocol rewards
    /// @dev Must implement reward claiming and selling logic. Can be no-op if no rewards.
    function _claimAndSellRewards() internal virtual;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the loose asset balance held by the strategy
    /// @dev Override if asset is held in a different form or location.
    /// @return The amount of asset tokens held by this contract
    function balanceOfAsset() public view virtual returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Get the loose collateral token balance held by the strategy
    /// @dev Override if collateral tokens are held in a different form or location.
    /// @return The amount of collateral tokens held by this contract (not supplied to protocol)
    function balanceOfCollateralToken() public view virtual returns (uint256) {
        return ERC20(collateralToken).balanceOf(address(this));
    }

    /// @notice Get collateral value in asset terms
    /// @dev price is in ORACLE_PRICE_SCALE (1e36), so we divide by 1e36
    function _collateralToAsset(
        uint256 collateralAmount
    ) internal view virtual returns (uint256) {
        if (collateralAmount == 0 || collateralAmount == type(uint256).max)
            return collateralAmount;
        return (collateralAmount * _getCollateralPrice()) / ORACLE_PRICE_SCALE;
    }

    /// @notice Get collateral amount for asset value
    /// @dev price is in ORACLE_PRICE_SCALE (1e36), so we multiply by 1e36
    function _assetToCollateral(
        uint256 assetAmount
    ) internal view virtual returns (uint256) {
        if (assetAmount == 0 || assetAmount == type(uint256).max)
            return assetAmount;
        uint256 collateralPrice = _getCollateralPrice();
        return (assetAmount * ORACLE_PRICE_SCALE) / collateralPrice;
    }

    /// @notice Get current leverage ratio
    function getCurrentLeverageRatio() public view virtual returns (uint256) {
        (uint256 collateralValue, uint256 debt) = position();
        if (collateralValue == 0) return 0;
        if (debt >= collateralValue) return type(uint256).max;
        return (collateralValue * WAD) / (collateralValue - debt);
    }

    /// @notice Get current LTV
    function getCurrentLTV() external view virtual returns (uint256) {
        (uint256 collateralValue, uint256 debt) = position();
        return collateralValue > 0 ? (debt * WAD) / collateralValue : 0;
    }

    /// @notice Get the current position details
    /// @dev Override to customize position calculation.
    /// @return collateralValue The value of collateral in asset terms
    /// @return debt The current debt amount
    function position()
        public
        view
        virtual
        returns (uint256 collateralValue, uint256 debt)
    {
        uint256 collateral = balanceOfCollateral();
        collateralValue = _collateralToAsset(collateral);
        debt = balanceOfDebt();
    }

    /// @notice Calculate the target position for a given equity amount
    /// @dev Used to determine how much collateral and debt to have at target leverage.
    /// @param _equity The equity (collateral - debt) to base calculations on
    /// @return collateral The target collateral amount
    /// @return debt The target debt amount
    function getTargetPosition(
        uint256 _equity
    ) public view virtual returns (uint256 collateral, uint256 debt) {
        uint256 targetCollateral = (_equity * targetLeverageRatio) / WAD;
        uint256 targetDebt = targetCollateral > _equity
            ? targetCollateral - _equity
            : 0;

        return (targetCollateral, targetDebt);
    }

    /// @notice Get amount out with slippage
    function _getAmountOut(
        uint256 amount,
        bool assetToCollateral
    ) internal view virtual returns (uint256) {
        if (amount == 0) return 0;
        uint256 converted = assetToCollateral
            ? _assetToCollateral(amount)
            : _collateralToAsset(amount);
        return (converted * (MAX_BPS - slippage)) / MAX_BPS;
    }

    /// @notice Check if the current base fee is acceptable for tending
    /// @dev Override to customize gas price checks or disable them entirely.
    /// @return True if the base fee is at or below maxGasPriceToTend
    function _isBaseFeeAcceptable() internal view virtual returns (bool) {
        return block.basefee <= maxGasPriceToTend;
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency full position close via flashloan
    function manualFullUnwind() external accrue onlyEmergencyAuthorized {
        _withdrawFunds(TokenizedStrategy.totalAssets());
    }

    function settle() external accrue onlyEmergencyAuthorized {
        address from = activeAuctionToken;
        require(from != address(0), "!auction");
        _clearAuctionState(from);
    }

    /// @notice Manual: supply collateral
    function manualSupplyCollateral(
        uint256 amount
    ) external accrue onlyEmergencyAuthorized {
        _supplyCollateral(Math.min(amount, balanceOfCollateralToken()));
    }

    /// @notice Manual: withdraw collateral
    function manualWithdrawCollateral(
        uint256 amount
    ) external accrue onlyEmergencyAuthorized {
        _withdrawCollateral(Math.min(amount, balanceOfCollateral()));
    }

    /// @notice Manual: borrow from protocol
    function manualBorrow(
        uint256 amount
    ) external accrue onlyEmergencyAuthorized {
        _borrow(amount);
    }

    /// @notice Manual: repay debt
    function manualRepay(
        uint256 amount
    ) external accrue onlyEmergencyAuthorized {
        _repay(Math.min(amount, balanceOfAsset()));
    }

    function convertCollateralToAsset(
        uint256 amount
    ) external accrue onlyEmergencyAuthorized {
        _kickAuction(
            collateralToken,
            address(asset),
            Math.min(amount, balanceOfCollateralToken() + balanceOfCollateral())
        );
    }

    function convertAssetToCollateral(
        uint256 amount
    ) external accrue onlyEmergencyAuthorized {
        _kickAuction(
            address(asset),
            collateralToken,
            Math.min(amount, balanceOfAsset())
        );
    }

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency withdraw funds from the leveraged position
    /// @dev Override to customize emergency withdrawal behavior. Default attempts full unwind via deleverage.
    ///      Called during emergency shutdown.
    /// @param _amount The amount of asset to attempt to withdraw
    function _emergencyWithdraw(
        uint256 _amount
    ) internal virtual override accrue {
        // Try full unwind first
        if (balanceOfDebt() > 0) {
            _withdrawFunds(Math.min(_amount, TokenizedStrategy.totalAssets()));
        } else if (_amount > 0) {
            _amount = Math.min(_amount, balanceOfCollateral());
            _withdrawCollateral(_amount);
            _executeSwap(
                collateralToken,
                address(asset),
                _amount,
                _getAmountOut(_amount, false),
                bytes("")
            );
        }
    }
}
