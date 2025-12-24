// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseLooper} from "../BaseLooper.sol";
import {IPool} from "../interfaces/aave/IPool.sol";
import {IFlashLoanSimpleReceiver} from "../interfaces/aave/IFlashLoanSimpleReceiver.sol";
import {IPoolDataProvider} from "../interfaces/aave/IPoolDataProvider.sol";
import {IPoolAddressesProvider} from "../interfaces/aave/IPoolAddressesProvider.sol";
import {IAaveOracle} from "../interfaces/aave/IAaveOracle.sol";
import {IRewardsController} from "../interfaces/aave/IRewardsController.sol";
import {IAToken} from "../interfaces/aave/IAToken.sol";
import {AuctionSwapper} from "@periphery/swappers/AuctionSwapper.sol";

/**
 * @title BaseAaveLooper
 * @notice Aave V3 specific implementation of BaseLooper.
 *         Implements the flashloan callback and protocol-specific operations.
 *         All generic flashloan logic and calculations live in BaseLooper.
 */
abstract contract BaseAaveLooper is
    BaseLooper,
    IFlashLoanSimpleReceiver,
    AuctionSwapper
{
    using SafeERC20 for ERC20;

    /// @notice Interest rate mode: 2 = variable rate
    uint256 internal constant VARIABLE_RATE_MODE = 2;

    /// @notice Referral code (0 for no referral)
    uint16 internal constant REFERRAL_CODE = 0;

    /// @notice Aave V3 Pool Addresses Provider
    IPoolAddressesProvider public immutable addressesProvider;

    /// @notice Aave V3 Pool
    IPool public immutable pool;

    /// @notice Aave V3 Data Provider
    IPoolDataProvider public immutable dataProvider;

    /// @notice Aave V3 Oracle
    IAaveOracle public immutable aaveOracle;

    /// @notice Aave V3 Rewards Controller
    IRewardsController public immutable rewardsController;

    /// @notice aToken address for collateral
    address public immutable aToken;

    /// @notice aToken address for the asset (borrow token) - used for liquidity checks
    address public immutable assetAToken;

    /// @notice Variable debt token address for the asset (borrow token)
    address public immutable variableDebtToken;

    /// @notice Cached decimals for collateral token
    uint256 internal immutable collateralDecimals;

    /// @notice Cached decimals for asset token
    uint256 internal immutable assetDecimals;

    /// @notice E-Mode category ID (0 = no eMode)
    uint8 public immutable eModeCategoryId;

    /// @notice Flashloan reentrancy guard
    bool internal isFlashloanActive;

    /// @notice Flashloan premium for current operation (stored during callback)
    uint256 internal currentFlashloanPremium;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _addressesProvider,
        uint8 _eModeCategoryId
    ) BaseLooper(_asset, _name, _collateralToken) {
        addressesProvider = IPoolAddressesProvider(_addressesProvider);
        pool = IPool(addressesProvider.getPool());
        dataProvider = IPoolDataProvider(
            addressesProvider.getPoolDataProvider()
        );
        aaveOracle = IAaveOracle(addressesProvider.getPriceOracle());

        // Get aToken address for collateral
        (address _aToken, , ) = dataProvider.getReserveTokensAddresses(
            _collateralToken
        );
        aToken = _aToken;

        // Get rewards controller from the aToken
        rewardsController = IRewardsController(
            IAToken(_aToken).getIncentivesController()
        );

        // Get aToken and variable debt token for the asset (borrow token)
        (address _assetAToken, , address _variableDebtToken) = dataProvider
            .getReserveTokensAddresses(_asset);
        assetAToken = _assetAToken;
        variableDebtToken = _variableDebtToken;

        // Cache decimals to avoid repeated external calls
        collateralDecimals = ERC20(_collateralToken).decimals();
        assetDecimals = ERC20(_asset).decimals();

        // Set E-Mode category for better capital efficiency on correlated assets
        eModeCategoryId = _eModeCategoryId;
        if (_eModeCategoryId != 0) {
            pool.setUserEMode(_eModeCategoryId);
        }

        // Approve pool for asset and collateral
        ERC20(_asset).forceApprove(address(pool), type(uint256).max);
        ERC20(_collateralToken).forceApprove(address(pool), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        IFlashLoanSimpleReceiver
    //////////////////////////////////////////////////////////////*/

    function ADDRESSES_PROVIDER() external view override returns (address) {
        return address(addressesProvider);
    }

    function POOL() external view override returns (address) {
        return address(pool);
    }

    /*//////////////////////////////////////////////////////////////
                        FLASHLOAN IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute flashloan through Aave V3
    function _executeFlashloan(
        address token,
        uint256 amount,
        bytes memory data
    ) internal override {
        isFlashloanActive = true;
        pool.flashLoanSimple(
            address(this), // receiver
            token,
            amount,
            data,
            REFERRAL_CODE
        );
        isFlashloanActive = false;
    }

    /// @notice Aave V3 flashloan callback - CRITICAL SECURITY FUNCTION
    /// @dev Only callable by Aave Pool during flashLoanSimple execution
    function executeOperation(
        address _asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == address(pool), "!pool");
        require(initiator == address(this), "!initiator");
        require(isFlashloanActive, "!flashloan active");

        // Store premium for _executeLeverageCallback to use
        currentFlashloanPremium = premium;

        // Delegate to parent's generic handler
        _onFlashloanReceived(amount, params);

        // Pool already has max approval from constructor - no need to re-approve
        // The pool will pull (amount + premium) on flashloan exit

        return true;
    }

    /// @notice Max available flashloan from Aave
    function maxFlashloan() public view override returns (uint256) {
        // Aave flashloan is limited by the liquidity in the pool (asset's aToken)
        return ERC20(address(asset)).balanceOf(assetAToken);
    }

    /// @notice Override to borrow flashloan amount + premium
    /// @dev Aave charges 0.05% premium on flashloans that must be repaid
    function _executeLeverageCallback(
        uint256 flashloanAmount,
        FlashLoanData memory params
    ) internal virtual override {
        // Total asset to convert = deposit + flashloan
        uint256 totalToConvert = params.amount + flashloanAmount;

        // Convert all asset to collateral
        uint256 collateralReceived = _convertAssetToCollateral(totalToConvert);

        // Supply collateral
        _supplyCollateral(collateralReceived);

        // Borrow to repay flashloan + premium (Aave charges 0.05% premium)
        _borrow(flashloanAmount + currentFlashloanPremium);
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Get oracle price (loan token value per 1 collateral token, 1e36 scale)
    /// @dev Aave oracle returns prices in BASE_CURRENCY_UNIT (usually USD with 8 decimals)
    ///      We need to return collateral/asset price ratio in 1e36 scale
    function _getCollateralPrice()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        uint256 collateralPrice = aaveOracle.getAssetPrice(collateralToken);
        uint256 assetPrice = aaveOracle.getAssetPrice(address(asset));

        if (assetPrice == 0) return 0;

        // Both prices are in same denomination (USD), compute ratio
        // Adjust for decimal differences between collateral and asset
        // price = (collateralPrice * 10^assetDecimals * ORACLE_PRICE_SCALE) /
        //         (assetPrice * 10^collateralDecimals)
        return
            (collateralPrice * (10 ** assetDecimals) * ORACLE_PRICE_SCALE) /
            (assetPrice * (10 ** collateralDecimals));
    }

    /*//////////////////////////////////////////////////////////////
                    AAVE PROTOCOL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function _supplyCollateral(uint256 amount) internal override {
        if (amount == 0) return;
        pool.supply(collateralToken, amount, address(this), REFERRAL_CODE);

        // Enable as collateral (idempotent - safe to call multiple times)
        pool.setUserUseReserveAsCollateral(collateralToken, true);
    }

    function _withdrawCollateral(uint256 amount) internal override {
        if (amount == 0) return;
        pool.withdraw(collateralToken, amount, address(this));
    }

    function _borrow(uint256 amount) internal virtual override {
        if (amount == 0) return;
        pool.borrow(
            address(asset),
            amount,
            VARIABLE_RATE_MODE,
            REFERRAL_CODE,
            address(this)
        );
    }

    function _repay(uint256 amount) internal virtual override {
        if (amount == 0) return;
        pool.repay(address(asset), amount, VARIABLE_RATE_MODE, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _isSupplyPaused() internal view virtual override returns (bool) {
        return dataProvider.getPaused(collateralToken);
    }

    function _isBorrowPaused() internal view virtual override returns (bool) {
        bool isPaused = dataProvider.getPaused(address(asset));
        if (isPaused) return true;

        // Also check if borrowing is enabled and not frozen
        (, , , , , , bool borrowingEnabled, , , bool isFrozen) = dataProvider
            .getReserveConfigurationData(address(asset));
        return isFrozen || !borrowingEnabled;
    }

    function _isLiquidatable() internal view virtual override returns (bool) {
        (, , , , , uint256 healthFactor) = pool.getUserAccountData(
            address(this)
        );
        // Health factor < 1e18 means liquidatable
        return healthFactor < 1e18 && healthFactor > 0;
    }

    function _maxCollateralDeposit()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        (, uint256 supplyCap) = dataProvider.getReserveCaps(collateralToken);
        if (supplyCap == 0) return type(uint256).max;

        uint256 currentSupply = dataProvider.getATokenTotalSupply(
            collateralToken
        );
        uint256 supplyCapInTokens = supplyCap * (10 ** collateralDecimals);

        return
            supplyCapInTokens > currentSupply
                ? supplyCapInTokens - currentSupply
                : 0;
    }

    function _maxBorrowAmount()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        (uint256 borrowCap, ) = dataProvider.getReserveCaps(address(asset));
        if (borrowCap == 0) {
            // No cap, return available liquidity
            return ERC20(address(asset)).balanceOf(assetAToken);
        }

        uint256 currentDebt = dataProvider.getTotalDebt(address(asset));
        uint256 borrowCapInTokens = borrowCap * (10 ** assetDecimals);

        return
            borrowCapInTokens > currentDebt
                ? borrowCapInTokens - currentDebt
                : 0;
    }

    function getLiquidateCollateralFactor()
        public
        view
        virtual
        override
        returns (uint256)
    {
        (, , uint256 liquidationThreshold, , , , , , , ) = dataProvider
            .getReserveConfigurationData(collateralToken);
        // Aave returns in basis points (10000 = 100%), convert to WAD
        return liquidationThreshold * 1e14; // 10000 * 1e14 = 1e18
    }

    function balanceOfCollateral()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return ERC20(aToken).balanceOf(address(this));
    }

    function balanceOfDebt() public view virtual override returns (uint256) {
        return ERC20(variableDebtToken).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            REWARDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim all rewards from Aave incentives controller
    function _claimAndSellRewards() internal virtual override {
        address[] memory assets = new address[](2);
        assets[0] = aToken;
        assets[1] = variableDebtToken;

        // Claim all rewards to this contract
        rewardsController.claimAllRewardsToSelf(assets);
    }

    function setAuction(address _auction) external onlyManagement {
        _setAuction(_auction);
    }

    function setUseAuction(bool _useAuction) external onlyManagement {
        _setUseAuction(_useAuction);
    }

    function kickAuction(
        address _token
    ) external override onlyKeepers returns (uint256) {
        return _kickAuction(_token);
    }
}
