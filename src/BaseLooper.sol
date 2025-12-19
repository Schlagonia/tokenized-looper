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

    // TODO: HOW do we set it to unwind, or just hold collataeral? Is 0 target possible?
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

    function _deployFunds(uint256 _amount) internal virtual override accrue {}

    function _freeFunds(uint256 _amount) internal virtual override accrue {
        _delever(_amount);
    }

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

    function estimatedTotalAssets() public view virtual returns (uint256) {
        return
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

        uint256 _targetLeverageRatio = targetLeverageRatio;
        if (_targetLeverageRatio <= WAD) return 0;

        uint256 maxDepositFromCollateral = _maxCollateralDeposit();
        if (maxDepositFromCollateral == 0) return 0;

        // Max collateral capacity converted to deposit amount
        // Total collateral = deposit * L, so deposit = collateral / L
        maxDepositFromCollateral = maxDepositFromCollateral == type(uint256).max
            ? maxDepositFromCollateral
            : (_collateralToAsset(maxDepositFromCollateral) * WAD) /
                _targetLeverageRatio;

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

    function _tend(uint256 _totalIdle) internal virtual override accrue {
        _lever(_totalIdle);
        lastTend = block.timestamp;
    }

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

        if (balanceOfAsset() > minAmountToBorrow) {
            return _isBaseFeeAcceptable();
        }

        // Check if outside buffer zone
        uint256 upperBound = _targetLeverageRatio + leverageBuffer;
        uint256 lowerBound = _targetLeverageRatio - leverageBuffer;

        if (currentLeverage < lowerBound || currentLeverage > upperBound) {
            return _isBaseFeeAcceptable();
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
            uint256 flashloanAmount = targetDebt - currentDebt;

            // Cap total swap if maxAmountToSwap is set
            uint256 _maxAmountToSwap = maxAmountToSwap;
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
                uint256 remainder = _amount - debtToRepay;
                if (remainder > 0) {
                    _supplyCollateral(_convertAssetToCollateral(remainder));
                }
                return;
            }

            // First repay what is loose.
            _repay(_amount);
            debtToRepay -= _amount;

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
            _supplyCollateral(
                _convertAssetToCollateral(Math.min(_amount, maxAmountToSwap))
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
        uint256 amount,
        uint256 amountOutMin
    ) internal virtual returns (uint256);

    /// @notice Convert collateral tokens to asset
    function _convertCollateralToAsset(
        uint256 amount,
        uint256 amountOutMin
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
    /// @dev price is in ORACLE_PRICE_SCALE (1e36), so we divide by 1e36
    function _collateralToAsset(
        uint256 collateralAmount
    ) internal view virtual returns (uint256) {
        if (collateralAmount == 0) return 0;
        return (collateralAmount * _getCollateralPrice()) / ORACLE_PRICE_SCALE;
    }

    /// @notice Get collateral amount for asset value
    /// @dev price is in ORACLE_PRICE_SCALE (1e36), so we multiply by 1e36
    function _assetToCollateral(
        uint256 assetAmount
    ) internal view virtual returns (uint256) {
        if (assetAmount == 0) return 0;
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
