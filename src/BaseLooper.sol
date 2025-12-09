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

    uint256 internal constant WAD = 1e18;

    /// @notice Flashloan operation types
    enum FlashLoanOperation {
        LEVERAGE, // Deposit flow: increase leverage
        DELEVERAGE // Withdraw flow: decrease leverage
    }

    /// @notice Data passed through flashloan callback
    struct FlashLoanData {
        FlashLoanOperation operation;
        uint256 targetAmount; // Amount to deploy or free (in asset terms)
    }

    /// The token posted as collateral in the loop.
    address public immutable collateralToken;

    /// @notice Target leverage ratio in WAD (e.g., 3e18 = 3x leverage)
    /// @dev leverage = collateralValue / (collateralValue - debtValue) = 1 / (1 - LTV)
    uint256 public targetLeverageRatio;

    /// @notice Buffer tolerance in WAD (e.g., 0.5e18 = +/- 0.5x triggers tend)
    /// @dev Bounds are [targetLeverageRatio - buffer, targetLeverageRatio + buffer]
    uint256 public leverageBuffer;

    /// @notice Maximum leverage ratio in WAD (e.g., 10e18 = 10x leverage)
    /// Will trigger a tend if the current leverage ratio exceeds this value.
    uint256 public maxLeverageRatio;

    /// @notice Slippage tolerance (in basis points) for swaps.
    uint64 public slippage;

    /// The max the base fee (in gwei) will be for a tend.
    uint256 public maxGasPriceToTend;

    /// Lower limit on flashloan size.
    uint256 public minAmountToBorrow;

    uint256 public depositLimit;

    mapping(address => bool) public allowed;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken
    ) BaseHealthCheck(_asset, _name) {
        collateralToken = _collateralToken;

        depositLimit = type(uint256).max;

        // Leverage ratio defaults: 5x target, 0.5x buffer
        targetLeverageRatio = 3e18;
        leverageBuffer = 0.5e18;
        maxLeverageRatio = 5e18;

        maxGasPriceToTend = 200 * 1e9;
        slippage = 500;

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
        require(_targetLeverageRatio >= WAD, "leverage < 1x");
        require(_leverageBuffer >= 0.01e18, "buffer too small");
        require(_targetLeverageRatio > _leverageBuffer, "target < buffer");
        require(
            _maxLeverageRatio >= _targetLeverageRatio + _leverageBuffer,
            "max leverage < target + buffer"
        );

        // Ensure max leverage doesn't exceed LLT
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

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    function _deployFunds(uint256 _amount) internal virtual override {
        _lever(_amount);
    }

    function _freeFunds(uint256 _amount) internal virtual override {
        _delever(_amount);
    }

    function _harvestAndReport()
        internal
        virtual
        override
        returns (uint256 _totalAssets)
    {
        _claimAndSellRewards();

        _adjustPosition(
            Math.min(balanceOfAsset(), availableDepositLimit(address(this)))
        );

        _totalAssets =
            balanceOfAsset() +
            _collateralToAsset(balanceOfCollateral()) -
            balanceOfDebt();
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    function availableDepositLimit(
        address _owner
    ) public view virtual override returns (uint256) {
        if (!allowed[_owner]) return 0;

        if (_isSupplyPaused() || _isBorrowPaused()) return 0;

        uint256 totalAssets = TokenizedStrategy.totalAssets();
        uint256 limit = depositLimit > totalAssets
            ? depositLimit - totalAssets
            : 0;

        // TODO: maxCollateral is in collateral not asset
        uint256 maxDeposit = Math.min(_maxCollateralDeposit(), limit);
        uint256 maxBorrow = _maxBorrowAmount();

        if (maxBorrow == 0) return 0;

        // Calculate max deposit based on leverage ratio
        uint256 targetLTV = _getTargetLTV();
        if (targetLTV == 0) return 0;

        return Math.min(maxDeposit, (maxBorrow * WAD) / targetLTV);
    }

    function availableWithdrawLimit(
        address /*_owner*/
    ) public view virtual override returns (uint256) {
        return type(uint256).max;
    }

    function _tend(uint256 _totalIdle) internal virtual override {
        _adjustPosition(
            Math.min(_totalIdle, availableDepositLimit(address(this)))
        );
    }

    function _tendTrigger() internal view virtual override returns (bool) {
        if (_isLiquidatable()) return true;
        if (TokenizedStrategy.totalAssets() == 0) return false;
        if (_isSupplyPaused() || _isBorrowPaused()) return false;

        uint256 currentLeverage = getCurrentLeverageRatio();

        if (currentLeverage > maxLeverageRatio) {
            return true;
        }

        // Check if outside buffer zone
        uint256 upperBound = targetLeverageRatio + leverageBuffer;
        uint256 lowerBound = targetLeverageRatio - leverageBuffer;

        if (currentLeverage < lowerBound || currentLeverage > upperBound) {
            return _isBaseFeeAcceptable();
        }

        return false;
    }

    /*//////////////////////////////////////////////////////////////
                        FLASHLOAN OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adjust position to target leverage
    function _adjustPosition(uint256 _amount) internal virtual {
        uint256 currentLeverage = getCurrentLeverageRatio();

        // If above max pay down any debt and recalculate leverage.
        if (currentLeverage > maxLeverageRatio) {
            _repay(Math.min(balanceOfDebt(), balanceOfAsset()));
            currentLeverage = getCurrentLeverageRatio();
        }

        if (currentLeverage < targetLeverageRatio - leverageBuffer) {
            _lever(_amount);
        } else if (currentLeverage > targetLeverageRatio + leverageBuffer) {
            _delever(0);
        }
    }

    /// @notice Leverage position using flashloan
    function _lever(uint256 _amount) internal virtual {
        // Calculate target position
        (uint256 currentCollateralValue, uint256 currentDebt, ) = position();

        uint256 currentEquity = currentCollateralValue - currentDebt + _amount;

        (, uint256 targetDebt) = getTargetPosition(currentEquity);

        // Amount to flashloan
        uint256 flashloanAmount = targetDebt > currentDebt
            ? targetDebt - currentDebt
            : 0;

        if (flashloanAmount <= minAmountToBorrow) {
            // Just repay the debt directly without leverage
            _repay(Math.min(_amount, currentDebt));
            return;
        }

        bytes memory data = abi.encode(
            FlashLoanData({
                operation: FlashLoanOperation.LEVERAGE,
                targetAmount: _amount
            })
        );

        // Execute flashloan - callback will handle the leverage
        _executeFlashloan(address(asset), flashloanAmount, data);
    }

    /// @notice Deleverage position using flashloan
    function _delever(uint256 _amountNeeded) internal virtual {
        (uint256 valueOfCollateral, uint256 currentDebt, ) = position();

        if (currentDebt == 0) {
            // No debt, just withdraw collateral
            uint256 toWithdraw = Math.min(
                _assetToCollateral(_amountNeeded),
                balanceOfCollateral()
            );
            _withdrawCollateral(toWithdraw);
            _convertCollateralToAsset(toWithdraw);
        }

        uint256 equity = valueOfCollateral - currentDebt;

        uint256 targetEquity = equity > _amountNeeded
            ? equity - _amountNeeded
            : 0;
        (, uint256 targetDebt) = getTargetPosition(targetEquity);

        uint256 debtToRepay = currentDebt > targetDebt
            ? currentDebt - targetDebt
            : 0;
        uint256 collateralToWithdraw = _assetToCollateral(
            debtToRepay + _amountNeeded
        );

        if (debtToRepay == 0 && collateralToWithdraw != 0) {
            // No debt to repay, just withdraw collateral
            _withdrawCollateral(collateralToWithdraw);
            _convertCollateralToAsset(collateralToWithdraw);
            return;
        }

        bytes memory data = abi.encode(
            FlashLoanData({
                operation: FlashLoanOperation.DELEVERAGE,
                targetAmount: collateralToWithdraw
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
        uint256 totalToConvert = params.targetAmount + flashloanAmount;

        // Convert all asset to collateral
        uint256 collateralReceived = _convertAssetToCollateral(totalToConvert);
        require(
            collateralReceived >= _getAmountOut(totalToConvert, true),
            "slippage: collateral"
        );

        // Supply collateral
        _supplyCollateral(collateralReceived);

        // Borrow to repay flashloan
        _borrow(flashloanAmount);
    }

    function _executeDeleverageCallback(
        uint256 flashloanAmount,
        FlashLoanData memory params
    ) internal virtual {
        // Use flashloaned amount to repay debt
        _repay(Math.min(flashloanAmount, balanceOfDebt()));

        uint256 collateralToWithdraw = Math.min(
            params.targetAmount,
            balanceOfCollateral()
        );
        // Withdraw
        _withdrawCollateral(collateralToWithdraw);

        // Convert collateral back to asset
        uint256 assetReceived = _convertCollateralToAsset(collateralToWithdraw);
        require(
            assetReceived >= _getAmountOut(collateralToWithdraw, false),
            "slippage: asset"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency full position close via flashloan
    function manualFullUnwind() external onlyEmergencyAuthorized {
        _delever(TokenizedStrategy.totalAssets());
    }

    /// @notice Manual: supply collateral (converts asset to collateral first)
    function manualSupplyCollateral(
        uint256 amount
    ) external onlyEmergencyAuthorized {
        _supplyCollateral(Math.min(amount, balanceOfCollateralToken()));
    }

    /// @notice Manual: withdraw collateral (converts to asset)
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
                    ABSTRACT - PROTOCOL SPECIFIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute a flashloan through the protocol
    function _executeFlashloan(
        address token,
        uint256 amount,
        bytes memory data
    ) internal virtual;

    /// @notice Max available flashloan from protocol
    function maxFlashloan() public view virtual returns (uint256);

    /// @notice Get oracle price (collateral value per borrow token, 1e36 scale)
    function _getCollateralPrice() internal view virtual returns (uint256);

    /// @notice Supply collateral (with asset->collateral conversion)
    function _supplyCollateral(uint256 amount) internal virtual;

    /// @notice Withdraw collateral (with collateral->asset conversion)
    function _withdrawCollateral(uint256 amount) internal virtual;

    function _borrow(uint256 amount) internal virtual;

    function _repay(uint256 amount) internal virtual;

    function _isSupplyPaused() internal view virtual returns (bool);

    function _isBorrowPaused() internal view virtual returns (bool);

    function _isLiquidatable() internal view virtual returns (bool);

    function _maxCollateralDeposit() internal view virtual returns (uint256);

    function _maxBorrowAmount() internal view virtual returns (uint256);

    function getLiquidateCollateralFactor()
        public
        view
        virtual
        returns (uint256);

    function balanceOfCollateral() public view virtual returns (uint256);

    function balanceOfDebt() public view virtual returns (uint256);

    /// @notice Convert asset to collateral tokens
    function _convertAssetToCollateral(
        uint256 amount
    ) internal virtual returns (uint256);

    /// @notice Convert collateral tokens to asset
    function _convertCollateralToAsset(
        uint256 amount
    ) internal virtual returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function balanceOfAsset() public view virtual returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function balanceOfCollateralToken() public view virtual returns (uint256) {
        return ERC20(collateralToken).balanceOf(address(this));
    }

    /// @notice Get collateral value in asset terms
    function _collateralToAsset(
        uint256 collateralAmount
    ) internal view virtual returns (uint256) {
        if (collateralAmount == 0) return 0;
        return (collateralAmount * _getCollateralPrice()) / WAD;
    }

    /// @notice Get collateral amount for asset value
    function _assetToCollateral(
        uint256 assetAmount
    ) internal view virtual returns (uint256) {
        if (assetAmount == 0) return 0;
        uint256 price = _getCollateralPrice();
        return (assetAmount * WAD) / price;
    }

    /// @notice Get current leverage ratio
    function getCurrentLeverageRatio() public view virtual returns (uint256) {
        (uint256 collateralValue, uint256 debt, ) = position();
        if (collateralValue == 0) return WAD;
        if (debt >= collateralValue) return type(uint256).max;
        return (collateralValue * WAD) / (collateralValue - debt);
    }

    /// @notice Get current LTV
    function getCurrentLTV() external view virtual returns (uint256) {
        (, , uint256 currentLTV) = position();
        return currentLTV;
    }

    function position()
        public
        view
        virtual
        returns (uint256 collateralValue, uint256 debt, uint256 currentLTV)
    {
        uint256 collateral = balanceOfCollateral();
        collateralValue = _collateralToAsset(collateral);
        debt = balanceOfDebt();
        currentLTV = collateralValue > 0 ? (debt * WAD) / collateralValue : 0;
    }

    function getTargetPosition(
        uint256 _equity
    ) public view virtual returns (uint256 collateral, uint256 debt) {
        uint256 targetCollateral = (_equity * targetLeverageRatio) / WAD;
        uint256 targetDebt = targetCollateral - _equity;
        return (targetCollateral, targetDebt);
    }

    /// @notice Get target LTV derived from leverage ratio
    function _getTargetLTV() internal view virtual returns (uint256) {
        if (targetLeverageRatio <= WAD) return 0;
        return WAD - (WAD * WAD) / targetLeverageRatio;
    }

    /// @notice Get warning LTV (upper bound)
    function _getWarningLTV() internal view virtual returns (uint256) {
        uint256 warningLeverage = targetLeverageRatio + leverageBuffer;
        if (warningLeverage <= WAD) return 0;
        return WAD - (WAD * WAD) / warningLeverage;
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

    function _isBaseFeeAcceptable() internal view virtual returns (bool) {
        return block.basefee <= maxGasPriceToTend;
    }

    /*//////////////////////////////////////////////////////////////
                        HARVEST / TOKEN CONVERSIONS
    //////////////////////////////////////////////////////////////*/

    function _claimAndSellRewards() internal virtual;

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY
    //////////////////////////////////////////////////////////////*/

    function _emergencyWithdraw(uint256 _amount) internal virtual override {
        // Try full unwind first
        uint256 debt = balanceOfDebt();
        if (debt > 0) {
            _delever(Math.min(_amount, TokenizedStrategy.totalAssets()));
        } else if (_amount > 0) {
            _amount = Math.min(_amount, balanceOfCollateral());
            _withdrawCollateral(_amount);
            _convertCollateralToAsset(_amount);
        }
    }
}
