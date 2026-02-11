// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {BaseExchange} from "./Exchanges/BaseExchange.sol";
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

    enum Operation {
        SUPPLY,
        WITHDRAW,
        BORROW,
        REPAY,
        SWAP
    }

    struct OperationData {
        Operation operation;
        bytes data;
    }

    /// @notice Accrue interest before state changing functions
    modifier accrue() {
        _accrueInterest();
        _;
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    /// @notice Slippage tolerance (in basis points) for swaps.
    uint64 public slippage;

    /// @notice The amount to discount collateral by in reports in basis points.
    uint256 public reportBuffer;

    /// @notice The maximum amount of asset that can be deposited
    uint256 public depositLimit;

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

    /// The token posted as collateral in the loop.
    address public immutable collateralToken;

    address public immutable EXCHANGE;

    mapping(address => bool) public allowed;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _exchange
    ) BaseHealthCheck(_asset, _name) {
        EXCHANGE = _exchange;
        collateralToken = _collateralToken;

        depositLimit = type(uint256).max;
        // Allow self so we can use availableDepositLimit() to get the max deposit amount.
        allowed[address(this)] = true;

        // Leverage ratio defaults: 3x target, 0.5x buffer
        targetLeverageRatio = 3e18;
        leverageBuffer = 0.25e18;
        maxLeverageRatio = 4e18;

        maxGasPriceToTend = 200 * 1e9;
        slippage = 30;

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

    function setReportBuffer(uint256 _reportBuffer) external onlyManagement {
        require(_reportBuffer < MAX_BPS, "buffer");
        reportBuffer = _reportBuffer;
    }

    /*//////////////////////////////////////////////////////////////
                            WORK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function doWork(bytes calldata data, bool flashloan, uint256 amount) external {
        uint256 startLeverage = getCurrentLeverageRatio();

        if (flashloan) {
            _executeFlashloan(address(asset), amount, data);
        } else {
            _executeOperations(data);
        }

        uint256 endLeverage = getCurrentLeverageRatio();
        require(endLeverage <= maxLeverageRatio || endLeverage < startLeverage, "leverage ratio exceeded");
    }

    function _onFlashloanReceived(bytes memory data) internal override {
        _executeOperations(data);
    }

    function _executeOperations(bytes memory data) internal {
        OperationData[] memory operations = abi.decode(data, (OperationData[]));
        for (uint256 i = 0; i < operations.length; i++) {
            OperationData memory operation = operations[i];
            if (operation.operation == Operation.SUPPLY) {
                _supplyCollateral(abi.decode(operation.data, (uint256)));
            } else if (operation.operation == Operation.WITHDRAW) {
                _withdrawCollateral(abi.decode(operation.data, (uint256)));
            } else if (operation.operation == Operation.BORROW) {
                _borrow(abi.decode(operation.data, (uint256)));
            } else if (operation.operation == Operation.REPAY) {
                _repay(abi.decode(operation.data, (uint256)));
            } else if (operation.operation == Operation.SWAP) {
                _swap(abi.decode(operation.data, (address, uint256, bytes)));
            }
        }
    }

    function _swap(address tokenIn, uint256 amountIn, bytes memory data) internal {
        if (amountIn == type(uint256).max) {
            amountIn = ERC20(tokenIn).balanceOf(address(this));
        }
        
        address tokenOut = tokenIn == address(asset) ? collateralToken : address(asset);
        uint256 minAmountOut = _getAmountOut(amountIn, tokenIn == address(asset));

        uint256 startBalance = ERC20(tokenOut).balanceOf(address(this));

        ERC20(tokenIn).forceApprove(EXCHANGE, amountIn);
        BaseExchange(EXCHANGE).exchange(tokenIn, tokenOut, amountIn, data);
        ERC20(tokenOut).forceApprove(EXCHANGE, 0);

        uint256 endBalance = ERC20(tokenOut).balanceOf(address(this));
        require(endBalance >= startBalance + minAmountOut, "insufficient output");
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
    function _freeFunds(uint256 _amount) internal virtual override accrue {}

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

        uint256 totalAssets = TokenizedStrategy.totalAssets();
        uint256 limit = depositLimit > totalAssets
            ? depositLimit - totalAssets
            : 0;

        return limit;
    }

    /// @notice Calculate the maximum amount that can be withdrawn by an address
    /// @dev Override to customize withdraw limits. Default returns max uint256 if flashloan covers debt,
    ///      otherwise calculates based on flashloan availability and target leverage.
    ///      The owner parameter is unused in default implementation.
    /// @return The maximum amount that can be withdrawn
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view virtual override returns (uint256) {
        return balanceOfAsset();
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

        uint256 _targetLeverageRatio = targetLeverageRatio;
        if (_targetLeverageRatio == 0) {
            return currentLeverage > 0 && _isBaseFeeAcceptable();
        }

        // If we are over the upper bound
        if (currentLeverage > _targetLeverageRatio + leverageBuffer) {
            // Over-leveraged: can repay with idle assets OR delever via flashloan
            if (
                balanceOfAsset() > minAmountToBorrow ||
                maxFlashloan() > minAmountToBorrow
            ) {
                return _isBaseFeeAcceptable();
            }
            return false;
        }
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
                            EMERGENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency withdraw funds from the leveraged position
    /// @dev Override to customize emergency withdrawal behavior. Default attempts full unwind via deleverage.
    ///      Called during emergency shutdown.
    /// @param _amount The amount of asset to attempt to withdraw
    function _emergencyWithdraw(uint256 _amount) internal virtual override {
        _withdrawCollateral(Math.min(balanceOfCollateralToken(), _amount));
    }
}
