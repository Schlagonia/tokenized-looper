// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";

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

    /// @notice Accrue interest before state changing functions
    modifier accrue() {
        _accrueInterest();
        _;
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    /// @notice Flashloan operation types
    enum FlashLoanOperation {
        LEVERAGE, // Deposit flow: increase leverage
        DELEVERAGE // Withdraw flow: decrease leverage
    }

    /// @notice Data passed through flashloan callback
    struct FlashLoanData {
        FlashLoanOperation operation;
        uint256 amount; // Amount to deploy or free (in asset terms)
    }

    /// @notice Slippage tolerance (in basis points) for swaps.
    uint64 public slippage;

    /// @notice The timestamp of the last tend.
    uint256 public lastTend;

    /// @notice The minimum interval between tends.
    uint256 public minTendInterval;

    /// @notice The maximum amount of asset that can be deposited
    uint256 public depositLimit;

    /// @notice Maximum amount of asset to swap in a single tend (0 = no limit)
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

    mapping(address => bool) public allowed;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken
    ) BaseHealthCheck(_asset, _name) {
        collateralToken = _collateralToken;

        depositLimit = type(uint256).max;
        // Allow self so we can use availableDepositLimit() to get the max deposit amount.
        allowed[address(this)] = true;

        // Leverage ratio defaults: 3x target, 0.5x buffer
        targetLeverageRatio = 3e18;
        leverageBuffer = 0.25e18;
        maxLeverageRatio = 4e18;

        minTendInterval = 2 hours;
        maxAmountToSwap = type(uint256).max;
        maxGasPriceToTend = 200 * 1e9;
        slippage = 50;

        _setLossLimitRatio(10);
        _setProfitLimitRatio(1_000);
    }

    /*//////////////////////////////////////////////////////////////
                            SETTERS
    //////////////////////////////////////////////////////////////*/

    function setDepositLimit(uint256 _depositLimit) external onlyManagement {
        depositLimit = _depositLimit;
    }

    function setAllowed(
        address _address,
        bool _allowed
    ) external onlyManagement {
        allowed[_address] = _allowed;
    }

    function setLeverageParams(
        uint256 _targetLeverageRatio,
        uint256 _leverageBuffer,
        uint256 _maxLeverageRatio
    ) external onlyManagement {
        if (_targetLeverageRatio == 0) {
            require(_leverageBuffer == 0, "buffer must be 0 if target is 0");
        } else {
            require(_targetLeverageRatio >= WAD, "leverage < 1x");
            require(_leverageBuffer >= 0.01e18, "buffer too small");
            require(_targetLeverageRatio > _leverageBuffer, "target < buffer");
        }

        require(
            _maxLeverageRatio >= _targetLeverageRatio + _leverageBuffer,
            "max leverage < target + buffer"
        );

        // Ensure max leverage doesn't exceed LLTV
        uint256 maxLTV = WAD - (WAD * WAD) / _maxLeverageRatio;
        require(maxLTV < getLiquidateCollateralFactor(), "exceeds LLTV");

        targetLeverageRatio = _targetLeverageRatio;
        leverageBuffer = _leverageBuffer;
        maxLeverageRatio = _maxLeverageRatio;
    }

    function setMaxGasPriceToTend(
        uint256 _maxGasPriceToTend
    ) external onlyManagement {
        maxGasPriceToTend = _maxGasPriceToTend;
    }

    function setSlippage(uint256 _slippage) external onlyManagement {
        require(_slippage < MAX_BPS, "slippage");
        slippage = uint64(_slippage);
    }

    function setMinAmountToBorrow(
        uint256 _minAmountToBorrow
    ) external onlyManagement {
        minAmountToBorrow = _minAmountToBorrow;
    }

    function setMinTendInterval(
        uint256 _minTendInterval
    ) external onlyManagement {
        minTendInterval = _minTendInterval;
    }

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
        _delever(_amount);
    }

    /// @notice Harvest rewards and report total assets
    /// @dev Override to customize harvesting behavior. Default claims rewards, levers up idle assets,
    ///      and reports total assets. Called during strategy reports.
    /// @return _totalAssets The total assets held by the strategy
    function _harvestAndReport()
        internal
        virtual
        override
        accrue
        returns (uint256 _totalAssets)
    {
        _claimAndSellRewards();

        _lever(
            Math.min(balanceOfAsset(), availableDepositLimit(address(this)))
        );

        _totalAssets = estimatedTotalAssets();
    }

    /// @notice Calculate the estimated total assets of the strategy
    /// @dev Override to customize asset calculation. Default returns loose assets + collateral value - debt.
    /// @return The estimated total assets in asset token terms
    function estimatedTotalAssets() public view virtual returns (uint256) {
        return
            balanceOfAsset() +
            _collateralToAsset(
                balanceOfCollateral() + balanceOfCollateralToken()
            ) -
            balanceOfDebt();
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

        uint256 totalAssets = TokenizedStrategy.totalAssets();
        uint256 limit = depositLimit > totalAssets
            ? depositLimit - totalAssets
            : 0;

        uint256 _targetLeverageRatio = targetLeverageRatio;
        if (_targetLeverageRatio <= WAD) return 0;

        uint256 maxDepositFromCollateral = _maxCollateralDeposit();
        if (maxDepositFromCollateral == 0) return 0;

        // Max collateral capacity converted to deposit amount
        // Total collateral = deposit * L, so deposit = collateral / L
        if (maxDepositFromCollateral != type(uint256).max) {
            maxDepositFromCollateral =
                (_collateralToAsset(maxDepositFromCollateral) *
                    WAD *
                    (MAX_BPS + slippage)) / // Add slippage to account for swap values.
                _targetLeverageRatio /
                MAX_BPS;
        }

        // Max deposit based on borrow capacity
        // Debt = deposit * (L - 1), so deposit = debt / (L - 1)
        uint256 maxBorrow = _maxBorrowAmount();
        if (maxBorrow == 0) return 0;

        uint256 maxDepositFromBorrow = (maxBorrow * WAD) /
            (_targetLeverageRatio - WAD);

        return
            Math.min(
                limit,
                Math.min(maxDepositFromCollateral, maxDepositFromBorrow)
            );
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
        lastTend = block.timestamp;
    }

    /// @notice Check if the position needs rebalancing
    /// @dev Override to customize tend trigger logic. Default checks liquidation risk, leverage bounds,
    ///      idle assets, min tend interval, and gas price.
    /// @return True if a tend operation should be triggered
    function _tendTrigger() internal view virtual override returns (bool) {
        if (_isLiquidatable()) return true;
        if (TokenizedStrategy.totalAssets() == 0) return false;
        if (_isSupplyPaused() || _isBorrowPaused()) return false;

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
            // Over-leveraged: can repay with idle assets OR delever via flashloan
            if (
                balanceOfAsset() > 0 ||
                availableWithdrawLimit(address(this)) > 0
            ) {
                return _isBaseFeeAcceptable();
            }
            return false;
        }

        // If we have idle assets or are under the lower bound
        if (
            (balanceOfAsset() * (_targetLeverageRatio - WAD)) / WAD >
            minAmountToBorrow ||
            currentLeverage < _targetLeverageRatio - leverageBuffer
        ) {
            // We still need deposit capacity to supply
            return
                (availableDepositLimit(address(this)) *
                    (_targetLeverageRatio - WAD)) /
                    WAD >
                minAmountToBorrow &&
                _isBaseFeeAcceptable();
        }

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

        if (targetDebt > currentDebt) {
            // CASE 1: Need MORE debt → leverage up via flashloan
            uint256 flashloanAmount = Math.min(
                targetDebt - currentDebt,
                maxFlashloan()
            );

            // Cap total swap if maxAmountToSwap is set or collateral capacity is reached
            uint256 maxCollateralInAsset = _collateralToAsset(
                _maxCollateralDeposit()
            );
            uint256 _maxAmountToSwap = maxCollateralInAsset == type(uint256).max
                ? maxAmountToSwap
                : Math.min(
                    maxAmountToSwap,
                    (maxCollateralInAsset * (MAX_BPS - slippage)) / MAX_BPS
                );
            if (_maxAmountToSwap != type(uint256).max) {
                uint256 totalSwap = _amount + flashloanAmount;

                if (totalSwap > _maxAmountToSwap) {
                    if (_amount >= _maxAmountToSwap) {
                        // _amount alone exceeds max, just swap max and supply
                        _supplyCollateral(
                            _convertAssetToCollateral(_maxAmountToSwap)
                        );
                        return;
                    }
                    // Reduce flashloan to stay within limit
                    flashloanAmount = _maxAmountToSwap - _amount;
                }
            }

            if (flashloanAmount <= minAmountToBorrow) {
                // Too small for flashloan, just repay debt with available assets
                _repay(Math.min(_amount, balanceOfDebt()));
                return;
            }

            bytes memory data = abi.encode(
                FlashLoanData({
                    operation: FlashLoanOperation.LEVERAGE,
                    amount: _amount
                })
            );

            _executeFlashloan(address(asset), flashloanAmount, data);
        } else if (currentDebt > targetDebt) {
            // CASE 2: Need LESS debt → deleverage
            uint256 debtToRepay = currentDebt - targetDebt;

            if (_amount >= debtToRepay) {
                // _amount covers the debt repayment, just repay and supply the rest
                _repay(debtToRepay);
                _amount -= debtToRepay;
                if (_amount > 0) {
                    _convertAssetToCollateral(
                        Math.min(_amount, maxAmountToSwap)
                    );
                    // Cap remainder by collateral capacity
                    _supplyCollateral(
                        Math.min(
                            balanceOfCollateralToken(),
                            _maxCollateralDeposit()
                        )
                    );
                }
                return;
            }

            // First repay what is loose.
            _repay(_amount);
            debtToRepay -= _amount;

            // Cap flashloan by available liquidity
            debtToRepay = Math.min(debtToRepay, maxFlashloan());

            // Flashloan to repay debt, withdraw collateral to cover
            uint256 collateralToWithdraw = (_assetToCollateral(debtToRepay) *
                (MAX_BPS + slippage)) / MAX_BPS;

            bytes memory data = abi.encode(
                FlashLoanData({
                    operation: FlashLoanOperation.DELEVERAGE,
                    amount: collateralToWithdraw
                })
            );
            _executeFlashloan(address(asset), debtToRepay, data);
        } else {
            // CASE 3: At target debt → just deploy _amount if any
            _convertAssetToCollateral(Math.min(_amount, maxAmountToSwap));
            _supplyCollateral(
                Math.min(balanceOfCollateralToken(), _maxCollateralDeposit())
            );
        }
    }

    /// @notice Deleverage position using flashloan
    function _delever(uint256 _amountNeeded) internal virtual {
        (uint256 valueOfCollateral, uint256 currentDebt) = position();

        if (currentDebt == 0) {
            // No debt, just withdraw collateral
            uint256 toWithdraw = Math.min(
                _assetToCollateral(_amountNeeded),
                balanceOfCollateral()
            );
            _withdrawCollateral(toWithdraw);
            _convertCollateralToAsset(toWithdraw);
            return;
        }

        uint256 equity = valueOfCollateral - currentDebt;

        uint256 targetEquity = equity > _amountNeeded
            ? equity - _amountNeeded
            : 0;
        (, uint256 targetDebt) = getTargetPosition(targetEquity);

        uint256 debtToRepay = currentDebt > targetDebt // Add slippage to account for swap back.
            ? ((currentDebt - targetDebt) * (MAX_BPS + slippage)) / MAX_BPS
            : 0;

        // Cap flashloan by available liquidity
        debtToRepay = Math.min(debtToRepay, maxFlashloan());

        uint256 collateralToWithdraw = _assetToCollateral(
            debtToRepay + _amountNeeded
        );

        if (debtToRepay == 0 && collateralToWithdraw != 0) {
            // No debt to repay, just withdraw collateral
            _withdrawCollateral(collateralToWithdraw);
            _convertCollateralToAsset(collateralToWithdraw);
            return;
        }

        if (debtToRepay == 0) return;

        bytes memory data = abi.encode(
            FlashLoanData({
                operation: FlashLoanOperation.DELEVERAGE,
                amount: collateralToWithdraw
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

        if (params.operation == FlashLoanOperation.LEVERAGE) {
            _executeLeverageCallback(assets, params);
        } else if (params.operation == FlashLoanOperation.DELEVERAGE) {
            _executeDeleverageCallback(assets, params);
        } else {
            revert("invalid operation");
        }
    }

    function _executeLeverageCallback(
        uint256 flashloanAmount,
        FlashLoanData memory params
    ) internal virtual {
        // Total asset to convert = deposit + flashloan
        uint256 totalToConvert = params.amount + flashloanAmount;

        // Convert all asset to collateral
        uint256 collateralReceived = _convertAssetToCollateral(totalToConvert);

        // Supply collateral
        _supplyCollateral(collateralReceived);

        // Borrow to repay flashloan
        _borrow(flashloanAmount);

        // Sanity check
        require(
            getCurrentLeverageRatio() < maxLeverageRatio,
            "leverage too high"
        );
    }

    function _executeDeleverageCallback(
        uint256 flashloanAmount,
        FlashLoanData memory params
    ) internal virtual {
        // Use flashloaned amount to repay debt
        _repay(Math.min(flashloanAmount, balanceOfDebt()));

        uint256 collateralToWithdraw = Math.min(
            params.amount,
            balanceOfCollateral()
        );
        // Withdraw
        _withdrawCollateral(collateralToWithdraw);

        // Convert collateral back to asset
        _convertCollateralToAsset(collateralToWithdraw);

        // Sanity check
        require(
            getCurrentLeverageRatio() < maxLeverageRatio,
            "leverage too low"
        );
    }

    function _convertCollateralToAsset(
        uint256 amount
    ) internal returns (uint256) {
        return _convertCollateralToAsset(amount, _getAmountOut(amount, false));
    }

    function _convertAssetToCollateral(
        uint256 amount
    ) internal returns (uint256) {
        return _convertAssetToCollateral(amount, _getAmountOut(amount, true));
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

    /// @notice Convert asset tokens to collateral tokens
    /// @dev Must implement swap/conversion logic (e.g., via DEX, staking, or minting).
    /// @param amount The amount of asset to convert
    /// @param amountOutMin The minimum amount of collateral to receive (slippage protection)
    /// @return The amount of collateral tokens received
    function _convertAssetToCollateral(
        uint256 amount,
        uint256 amountOutMin
    ) internal virtual returns (uint256);

    /// @notice Convert collateral tokens back to asset tokens
    /// @dev Must implement swap/conversion logic (e.g., via DEX, unstaking, or redeeming).
    /// @param amount The amount of collateral to convert
    /// @param amountOutMin The minimum amount of asset to receive (slippage protection)
    /// @return The amount of asset tokens received
    function _convertCollateralToAsset(
        uint256 amount,
        uint256 amountOutMin
    ) internal virtual returns (uint256);

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
        uint256 price = _getCollateralPrice();
        return (assetAmount * ORACLE_PRICE_SCALE) / price;
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
    function manualFullUnwind() external onlyEmergencyAuthorized {
        _delever(TokenizedStrategy.totalAssets());
    }

    /// @notice Manual: supply collateral
    function manualSupplyCollateral(
        uint256 amount
    ) external onlyEmergencyAuthorized {
        _supplyCollateral(Math.min(amount, balanceOfCollateralToken()));
    }

    /// @notice Manual: withdraw collateral
    function manualWithdrawCollateral(
        uint256 amount
    ) external onlyEmergencyAuthorized {
        _withdrawCollateral(Math.min(amount, balanceOfCollateral()));
    }

    /// @notice Manual: borrow from protocol
    function manualBorrow(uint256 amount) external onlyEmergencyAuthorized {
        _borrow(amount);
    }

    /// @notice Manual: repay debt
    function manualRepay(uint256 amount) external onlyEmergencyAuthorized {
        _repay(Math.min(amount, balanceOfAsset()));
    }

    function convertCollateralToAsset(
        uint256 amount
    ) external onlyEmergencyAuthorized {
        _convertCollateralToAsset(Math.min(amount, balanceOfCollateralToken()));
    }

    function convertAssetToCollateral(
        uint256 amount
    ) external onlyEmergencyAuthorized {
        _convertAssetToCollateral(Math.min(amount, balanceOfAsset()));
    }

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency withdraw funds from the leveraged position
    /// @dev Override to customize emergency withdrawal behavior. Default attempts full unwind via deleverage.
    ///      Called during emergency shutdown.
    /// @param _amount The amount of asset to attempt to withdraw
    function _emergencyWithdraw(uint256 _amount) internal virtual override {
        // Try full unwind first
        if (balanceOfDebt() > 0) {
            _delever(Math.min(_amount, TokenizedStrategy.totalAssets()));
        } else if (_amount > 0) {
            _amount = Math.min(_amount, balanceOfCollateral());
            _withdrawCollateral(_amount);
            _convertCollateralToAsset(_amount);
        }
    }
}
