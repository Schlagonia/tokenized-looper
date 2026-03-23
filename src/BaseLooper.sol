// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {ITaker} from "@periphery/interfaces/ITaker.sol";
import {Maths} from "@periphery/libraries/Maths.sol";
import {IExchange} from "./interfaces/IExchange.sol";
import {ISwapAuction} from "./interfaces/ISwapAuction.sol";

/**
 * @title BaseLooper
 * @notice Shared leverage-looping logic using flashloans exclusively.
 *         Uses a fixed leverage ratio system with flashloan-based operations.
 *         Since asset == borrowToken, pricing uses a single oracle for collateral/asset conversion.
 *         Inheritors implement protocol specific hooks for flashloans, supplying collateral,
 *         borrowing, repaying, and oracle access.
 */
abstract contract BaseLooper is BaseHealthCheck, ITaker {
    using SafeERC20 for ERC20;

    modifier onlyGovernance() {
        require(msg.sender == GOVERNANCE, "!governance");
        _;
    }

    /// @notice Accrue interest before state changing functions
    modifier accrue() {
        _accrueInterest();
        _;
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_SLIPPAGE = 100;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant SWAP_AUCTION_LENGTH = 5 minutes;
    uint256 internal constant SWAP_AUCTION_STEP_DURATION = 5 seconds;
    uint256 internal constant SWAP_AUCTION_STEPS =
        SWAP_AUCTION_LENGTH / SWAP_AUCTION_STEP_DURATION;

    /// @notice Flashloan operation types
    enum FlashLoanOperation {
        LEVERAGE, // Deposit flow: increase leverage
        DELEVERAGE, // Withdraw flow: decrease leverage
        AUCTION_LEVERAGE // Auction take flow: send asset to taker and supply received collateral
    }

    enum SwapMode {
        DIRECT,
        AUCTION
    }

    /// @notice Data passed through flashloan callback
    struct FlashLoanData {
        FlashLoanOperation operation;
        uint256 amount; // Amount to deploy or free (in asset terms)
        address receiver;
        uint256 auxiliaryAmount;
        bytes swapData;
    }

    /// @notice Governance address allowed to update exchange configuration.
    address public immutable GOVERNANCE;

    /// @notice Slippage tolerance (in basis points) for swaps.
    uint64 public slippage;

    /// @notice Exchange address
    address public exchange;

    /// @notice Swap auction address used when tending in auction mode.
    address public swapAuction;

    /// @notice Mode used for tend/report leverage swaps.
    SwapMode public swapMode;

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

    bytes[] internal _forcedExitSwapData;
    uint256 internal _forcedExitSwapDataIndex;

    mapping(address => bool) public allowed;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _governance,
        address _exchange
    ) BaseHealthCheck(_asset, _name) {
        require(_governance != address(0), "!governance");
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
        slippage = 30;

        _setLossLimitRatio(10);
        _setProfitLimitRatio(500);

        if (_exchange != address(0)) {
            _setExchange(_exchange);
        }
    }

    function version() public pure virtual returns (string memory) {
        return "1.0.2";
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
        require(_slippage < MAX_BPS, "slippage");
        if (!TokenizedStrategy.isShutdown())
            require(_slippage < MAX_SLIPPAGE, "slippage too high");
        slippage = uint64(_slippage);
    }

    /// @notice Set the report buffer used when accounting for assets.
    /// @dev `estimatedTotalAssets` discounts collateral value by this BPS amount,
    ///       so increasing it makes reported assets more conservative.
    /// @param _reportBuffer Buffer in basis points.
    function setReportBuffer(uint256 _reportBuffer) external onlyManagement {
        require(_reportBuffer < MAX_BPS, "buffer");
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

    /// @notice Set the exchange contract used for asset/collateral swaps.
    /// @dev Resets token approvals on the old exchange and grants max approvals to the new one;
    ///      new exchange must support expected swap paths.
    /// @param _exchange New exchange address.
    function setExchange(address _exchange) external onlyGovernance {
        _setExchange(_exchange);
    }

    function setSwapAuction(address _swapAuction) external onlyGovernance {
        _setSwapAuction(_swapAuction);
    }

    function setSwapMode(SwapMode _swapMode) external onlyManagement {
        if (_swapMode == SwapMode.AUCTION) {
            require(swapAuction != address(0), "!swapAuction");
        }
        swapMode = _swapMode;
    }

    function _setExchange(address _exchange) internal virtual {
        require(_exchange != address(0), "!exchange");

        address oldExchange = exchange;
        if (oldExchange != address(0)) {
            asset.forceApprove(oldExchange, 0);
            ERC20(collateralToken).forceApprove(oldExchange, 0);
        }

        exchange = _exchange;
        asset.forceApprove(_exchange, type(uint256).max);
        ERC20(collateralToken).forceApprove(_exchange, type(uint256).max);
    }

    function _setSwapAuction(address _swapAuction) internal virtual {
        if (_swapAuction != address(0)) {
            require(
                ISwapAuction(_swapAuction).strategy() == address(this),
                "wrong strategy"
            );
        } else {
            require(swapMode != SwapMode.AUCTION, "auction mode");
        }

        swapAuction = _swapAuction;
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
        if (_forcedExitSwapData.length != 0) {
            _withdrawFundsWithSwapData(_amount);
            return;
        }

        _withdrawFunds(_amount);
    }

    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner,
        bytes[] calldata _swapData
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
        bytes[] calldata _swapData
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

        if (targetLeverageRatio <= WAD) return 0;

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
        if (_hasActiveSwapAuction()) return false;

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
        if (swapMode == SwapMode.AUCTION) {
            _leverAuction(_amount);
            return;
        }

        _leverDirect(_amount);
    }

    function _leverDirect(uint256 _amount) internal virtual {
        lastTend = block.timestamp;
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
                    amount: _amount,
                    receiver: address(0),
                    auxiliaryAmount: 0,
                    swapData: bytes("")
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

            // Cap delever swap size when requested.
            if (maxAmountToSwap != type(uint256).max) {
                debtToRepay = Math.min(debtToRepay, maxAmountToSwap);
            }

            if (debtToRepay == 0) return;

            // Flashloan to repay debt, withdraw collateral to cover
            uint256 collateralToWithdraw = (_assetToCollateral(debtToRepay) *
                (MAX_BPS + slippage)) / MAX_BPS;

            bytes memory data = abi.encode(
                FlashLoanData({
                    operation: FlashLoanOperation.DELEVERAGE,
                    amount: collateralToWithdraw,
                    receiver: address(0),
                    auxiliaryAmount: 0,
                    swapData: bytes("")
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

    function _leverAuction(uint256 _amount) internal virtual {
        (uint256 currentCollateralValue, uint256 currentDebt) = position();
        uint256 currentEquity = currentCollateralValue - currentDebt + _amount;
        (, uint256 targetDebt) = getTargetPosition(currentEquity);

        if (targetDebt > currentDebt) {
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

            _kickSwapAuction(
                ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL,
                totalSwap
            );
            return;
        }

        if (currentDebt > targetDebt) {
            uint256 debtToRepay = currentDebt - targetDebt;

            if (_amount >= debtToRepay) {
                _repay(debtToRepay);
                _amount -= debtToRepay;
                if (_amount > 0) {
                    _kickSwapAuction(
                        ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL,
                        Math.min(_amount, maxAmountToSwap)
                    );
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
            _kickSwapAuction(
                ISwapAuction.SwapDirection.COLLATERAL_TO_ASSET,
                collateralToWithdraw
            );
            return;
        }

        _kickSwapAuction(
            ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL,
            Math.min(_amount, maxAmountToSwap)
        );
    }

    /// @notice Will withdraw funds from the strategy to cover the amount needed keeping the position at target leverage ratio using a flashloan
    function _withdrawFunds(uint256 _amountNeeded) internal virtual {
        _withdrawFundsDirect(_amountNeeded, bytes(""));
    }

    function _withdrawFundsWithSwapData(uint256 _amountNeeded) internal virtual {
        while (balanceOfAsset() < _amountNeeded) {
            bytes memory swapData;
            if (_forcedExitSwapDataIndex < _forcedExitSwapData.length) {
                swapData = _forcedExitSwapData[_forcedExitSwapDataIndex];
                unchecked {
                    ++_forcedExitSwapDataIndex;
                }
            }

            uint256 balanceBefore = balanceOfAsset();
            _withdrawFundsDirect(_amountNeeded - balanceBefore, swapData);

            uint256 balanceAfter = balanceOfAsset();
            if (balanceAfter <= balanceBefore) {
                revert("!swapData");
            }
        }

        require(balanceOfAsset() >= _amountNeeded, "!swapData");
    }

    function _withdrawFundsDirect(
        uint256 _amountNeeded,
        bytes memory _swapData
    ) internal virtual {
        (uint256 valueOfCollateral, uint256 currentDebt) = position();

        if (currentDebt == 0) {
            // No debt, just withdraw collateral
            uint256 toWithdraw = _assetToCollateral(_amountNeeded);
            _withdrawCollateral(Math.min(toWithdraw, balanceOfCollateral()));
            _convertCollateralToAsset(
                Math.min(toWithdraw, balanceOfCollateralToken()),
                _getAmountOut(
                    Math.min(toWithdraw, balanceOfCollateralToken()),
                    false
                ),
                _swapData
            );
            return;
        }

        uint256 equity = valueOfCollateral - currentDebt;

        uint256 targetEquity = equity > _amountNeeded
            ? equity - _amountNeeded
            : 0;
        (, uint256 targetDebt) = getTargetPosition(targetEquity);

        if (targetDebt > currentDebt) {
            // No debt to repay, just withdraw collateral
            uint256 toWithdraw = _assetToCollateral(_amountNeeded);
            _withdrawCollateral(Math.min(toWithdraw, balanceOfCollateral()));
            _convertCollateralToAsset(
                toWithdraw,
                _getAmountOut(toWithdraw, false),
                _swapData
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
                receiver: address(0),
                auxiliaryAmount: 0,
                swapData: _swapData
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
        } else if (params.operation == FlashLoanOperation.AUCTION_LEVERAGE) {
            _executeAuctionLeverageCallback(assets, params);
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
        uint256 collateralReceived = _convertAssetToCollateral(
            totalToConvert,
            _getAmountOut(totalToConvert, true),
            params.swapData
        );

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
        _convertCollateralToAsset(
            collateralToWithdraw,
            _getAmountOut(collateralToWithdraw, false),
            params.swapData
        );

        // Sanity check
        uint256 finalLeverage = getCurrentLeverageRatio();
        // Make sure the leverage is within the bounds, or at least improved.
        require(
            finalLeverage < maxLeverageRatio || finalLeverage < initialLeverage,
            "leverage too high"
        );
    }

    function _executeAuctionLeverageCallback(
        uint256 flashloanAmount,
        FlashLoanData memory params
    ) internal virtual {
        asset.safeTransfer(params.receiver, params.amount);
        require(balanceOfCollateralToken() >= params.auxiliaryAmount, "!amount");
        _supplyCollateral(params.auxiliaryAmount);
        _borrow(flashloanAmount);

        require(
            getCurrentLeverageRatio() < maxLeverageRatio,
            "leverage too high"
        );
    }

    function _convertCollateralToAsset(
        uint256 amount
    ) internal virtual returns (uint256) {
        return
            _convertCollateralToAsset(
                amount,
                _getAmountOut(amount, false),
                ""
            );
    }

    function _convertAssetToCollateral(
        uint256 amount
    ) internal virtual returns (uint256) {
        return
            _convertAssetToCollateral(
                amount,
                _getAmountOut(amount, true),
                bytes("")
            );
    }

    function _convertAssetToCollateral(
        uint256 amount,
        uint256 amountOutMin
    ) internal virtual returns (uint256) {
        return _convertAssetToCollateral(amount, amountOutMin, bytes(""));
    }

    function _convertAssetToCollateral(
        uint256 amount,
        uint256 amountOutMin,
        bytes memory swapData
    ) internal virtual returns (uint256) {
        if (amount == 0) return 0;

        uint256 amountOut = swapData.length == 0
            ? IExchange(exchange).exchange(
                address(asset),
                collateralToken,
                amount,
                amountOutMin
            )
            : IExchange(exchange).exchange(
                address(asset),
                collateralToken,
                amount,
                amountOutMin,
                swapData
            );
        require(amountOut >= amountOutMin, "!amountOut");
        return amountOut;
    }

    function _convertCollateralToAsset(
        uint256 amount,
        uint256 amountOutMin
    ) internal virtual returns (uint256) {
        return _convertCollateralToAsset(amount, amountOutMin, bytes(""));
    }

    function _convertCollateralToAsset(
        uint256 amount,
        uint256 amountOutMin,
        bytes memory swapData
    ) internal virtual returns (uint256) {
        if (amount == 0) return 0;

        uint256 amountOut = swapData.length == 0
            ? IExchange(exchange).exchange(
                collateralToken,
                address(asset),
                amount,
                amountOutMin
            )
            : IExchange(exchange).exchange(
                collateralToken,
                address(asset),
                amount,
                amountOutMin,
                swapData
            );
        require(amountOut >= amountOutMin, "!amountOut");
        return amountOut;
    }

    function auctionTakeCallback(
        address _from,
        address _sender,
        uint256 _amountTaken,
        uint256 _amountNeeded,
        bytes calldata _data
    ) external virtual override accrue {
        require(msg.sender == swapAuction, "!auction");

        ISwapAuction auction = ISwapAuction(msg.sender);
        require(_from == auction.activeSellToken(), "!from");

        (address _receiver, bytes memory settlementData) = abi.decode(
            _data,
            (address, bytes)
        );
        // Reserved for taker-specific settlement parameters.
        settlementData;

        ISwapAuction.SwapDirection direction = auction.activeDirection();
        if (direction == ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL) {
            _settleAssetToCollateralAuction(
                _sender,
                _receiver,
                _amountTaken,
                _amountNeeded
            );
            return;
        }

        if (direction == ISwapAuction.SwapDirection.COLLATERAL_TO_ASSET) {
            _settleCollateralToAssetAuction(
                _sender,
                _receiver,
                _amountTaken,
                _amountNeeded
            );
            return;
        }

        revert("!direction");
    }

    function _settleAssetToCollateralAuction(
        address _sender,
        address _receiver,
        uint256 _amountTaken,
        uint256 _amountNeeded
    ) internal virtual {
        ERC20(collateralToken).safeTransferFrom(
            _sender,
            address(this),
            _amountNeeded
        );

        uint256 looseAsset = balanceOfAsset();
        if (looseAsset < _amountTaken) {
            bytes memory flashloanData = abi.encode(
                FlashLoanData({
                    operation: FlashLoanOperation.AUCTION_LEVERAGE,
                    amount: _amountTaken,
                    receiver: _receiver,
                    auxiliaryAmount: _amountNeeded,
                    swapData: bytes("")
                })
            );

            _executeFlashloan(
                address(asset),
                _amountTaken - looseAsset,
                flashloanData
            );
            return;
        }

        asset.safeTransfer(_receiver, _amountTaken);
        require(balanceOfCollateralToken() >= _amountNeeded, "!amount");
        _supplyCollateral(_amountNeeded);
    }

    function _settleCollateralToAssetAuction(
        address _sender,
        address _receiver,
        uint256 _amountTaken,
        uint256 _amountNeeded
    ) internal virtual {
        asset.safeTransferFrom(_sender, address(this), _amountNeeded);
        _repay(Math.min(_amountNeeded, balanceOfDebt()));

        require(balanceOfCollateral() >= _amountTaken, "!amount");
        _withdrawCollateral(_amountTaken);
        require(balanceOfCollateralToken() >= _amountTaken, "!amount");
        ERC20(collateralToken).safeTransfer(_receiver, _amountTaken);
    }

    function _kickSwapAuction(
        ISwapAuction.SwapDirection _direction,
        uint256 _amount
    ) internal virtual returns (bool) {
        if (_amount == 0) return false;

        address auctionAddress = swapAuction;
        require(auctionAddress != address(0), "!swapAuction");

        ISwapAuction auction = ISwapAuction(auctionAddress);
        address activeSell = auction.activeSellToken();
        if (activeSell != address(0)) {
            if (auction.isActive(activeSell)) {
                return false;
            }
            auction.settle(activeSell);
        }

        (
            address sellToken,
            address buyToken,
            uint256 startingPrice,
            uint256 minimumPrice
        ) = _getSwapAuctionConfig(_direction, _amount);

        auction.kick(
            sellToken,
            buyToken,
            _amount,
            _direction,
            startingPrice,
            minimumPrice,
            _getAuctionStepDecayRate(startingPrice, minimumPrice)
        );

        lastTend = block.timestamp;
        return true;
    }

    function _hasActiveSwapAuction() internal view returns (bool) {
        if (swapMode != SwapMode.AUCTION || swapAuction == address(0)) {
            return false;
        }

        address activeSell = ISwapAuction(swapAuction).activeSellToken();
        if (activeSell == address(0)) return false;

        return ISwapAuction(swapAuction).isActive(activeSell);
    }

    function _getSwapAuctionConfig(
        ISwapAuction.SwapDirection _direction,
        uint256 _amount
    )
        internal
        view
        returns (
            address sellToken,
            address buyToken,
            uint256 startingPrice,
            uint256 minimumPrice
        )
    {
        sellToken = _direction == ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL
            ? address(asset)
            : collateralToken;
        buyToken = _direction == ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL
            ? collateralToken
            : address(asset);

        uint256 quotedAmountOut = _direction ==
            ISwapAuction.SwapDirection.ASSET_TO_COLLATERAL
            ? _assetToCollateral(_amount)
            : _collateralToAsset(_amount);

        uint256 startBuffer = _getAuctionStartBufferBps();
        uint256 startingAmountOut = (quotedAmountOut *
            (MAX_BPS - startBuffer)) / MAX_BPS;
        uint256 minimumAmountOut = (quotedAmountOut * (MAX_BPS - slippage)) /
            MAX_BPS;

        startingPrice = _quoteToAuctionPrice(
            sellToken,
            buyToken,
            _amount,
            startingAmountOut
        );
        minimumPrice = _quoteToAuctionPrice(
            sellToken,
            buyToken,
            _amount,
            minimumAmountOut
        );

        if (startingPrice <= minimumPrice && minimumPrice != 0) {
            startingPrice = minimumPrice + 1;
        }
    }

    function _quoteToAuctionPrice(
        address _sellToken,
        address _buyToken,
        uint256 _sellAmount,
        uint256 _buyAmount
    ) internal view returns (uint256) {
        if (_sellAmount == 0 || _buyAmount == 0) return 0;

        uint256 sellScaler = WAD / (10 ** ERC20(_sellToken).decimals());
        uint256 buyScaler = WAD / (10 ** ERC20(_buyToken).decimals());
        return (_buyAmount * buyScaler * WAD) / (_sellAmount * sellScaler);
    }

    function _getAuctionStartBufferBps() internal view returns (uint256) {
        if (slippage <= 1) return 0;

        uint256 startBuffer = Math.max(1, uint256(slippage) / 5);
        return Math.min(startBuffer, uint256(slippage) - 1);
    }

    function _getAuctionStepDecayRate(
        uint256 _startingPrice,
        uint256 _minimumPrice
    ) internal pure returns (uint256) {
        if (_startingPrice <= _minimumPrice) {
            return 1;
        }

        uint256 low = 1;
        uint256 high = MAX_BPS - 1;
        uint256 best = 1;

        while (low <= high) {
            uint256 mid = (low + high) / 2;
            uint256 rayMultiplier = 1e27 - (mid * 1e23);
            uint256 endPrice = Maths.rmul(
                _startingPrice,
                Maths.rpow(rayMultiplier, SWAP_AUCTION_STEPS)
            );

            if (endPrice >= _minimumPrice) {
                best = mid;
                low = mid + 1;
            } else {
                high = mid - 1;
            }
        }

        return best;
    }

    function _setForcedExitSwapData(bytes[] calldata _swapData) internal {
        delete _forcedExitSwapData;
        _forcedExitSwapDataIndex = 0;

        uint256 length = _swapData.length;
        for (uint256 i; i < length; ) {
            _forcedExitSwapData.push();
            _forcedExitSwapData[i] = _swapData[i];
            unchecked {
                ++i;
            }
        }
    }

    function _clearForcedExitSwapData() internal {
        delete _forcedExitSwapData;
        _forcedExitSwapDataIndex = 0;
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
                        MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency full position close via flashloan
    function manualFullUnwind() external accrue onlyEmergencyAuthorized {
        _withdrawFunds(TokenizedStrategy.totalAssets());
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
        _convertCollateralToAsset(Math.min(amount, balanceOfCollateralToken()));
    }

    function convertAssetToCollateral(
        uint256 amount
    ) external accrue onlyEmergencyAuthorized {
        _convertAssetToCollateral(Math.min(amount, balanceOfAsset()));
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
            _convertCollateralToAsset(_amount);
        }
    }
}
