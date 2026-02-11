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
    IPoolAddressesProvider public immutable override ADDRESSES_PROVIDER;

    /// @notice Aave V3 Pool
    IPool public immutable override POOL;

    /// @notice Aave V3 Data Provider
    IPoolDataProvider public immutable DATA_PROVIDER;

    /// @notice Aave V3 Oracle
    IAaveOracle public immutable AAVE_ORACLE;

    /// @notice Aave V3 Rewards Controller
    IRewardsController public immutable REWARDS_CONTROLLER;

    /// @notice aToken address for collateral
    address public immutable A_TOKEN;

    /// @notice aToken address for the asset (borrow token) - used for liquidity checks
    address public immutable ASSET_A_TOKEN;

    /// @notice Variable debt token address for the asset (borrow token)
    address public immutable VARIABLE_DEBT_TOKEN;

    /// @notice Cached decimals for collateral token
    uint256 internal immutable COLLATERAL_DECIMALS;

    /// @notice Cached decimals for asset token
    uint256 internal immutable ASSET_DECIMALS;

    /// @notice E-Mode category ID (0 = no eMode)
    uint8 public immutable E_MODE_CATEGORY_ID;

    /// @notice Flashloan reentrancy guard
    bool internal isFlashloanActive;

    /// @notice Flashloan premium for current operation (stored during callback)
    uint256 internal currentFlashloanPremium;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _exchange,
        address _addressesProvider,
        uint8 _eModeCategoryId
    ) BaseLooper(_asset, _name, _collateralToken, _exchange) {
        ADDRESSES_PROVIDER = IPoolAddressesProvider(_addressesProvider);
        POOL = IPool(ADDRESSES_PROVIDER.getPool());
        DATA_PROVIDER = IPoolDataProvider(
            ADDRESSES_PROVIDER.getPoolDataProvider()
        );
        AAVE_ORACLE = IAaveOracle(ADDRESSES_PROVIDER.getPriceOracle());

        // Get aToken address for collateral
        (address _aToken, , ) = DATA_PROVIDER.getReserveTokensAddresses(
            _collateralToken
        );
        A_TOKEN = _aToken;

        // Get rewards controller from the aToken
        REWARDS_CONTROLLER = IRewardsController(
            IAToken(_aToken).getIncentivesController()
        );

        // Get aToken and variable debt token for the asset (borrow token)
        (address _assetAToken, , address _variableDebtToken) = DATA_PROVIDER
            .getReserveTokensAddresses(_asset);
        ASSET_A_TOKEN = _assetAToken;
        VARIABLE_DEBT_TOKEN = _variableDebtToken;

        // Cache decimals to avoid repeated external calls
        COLLATERAL_DECIMALS = ERC20(_collateralToken).decimals();
        ASSET_DECIMALS = ERC20(_asset).decimals();

        // Set E-Mode category for better capital efficiency on correlated assets
        E_MODE_CATEGORY_ID = _eModeCategoryId;
        if (_eModeCategoryId != 0) {
            POOL.setUserEMode(_eModeCategoryId);
        }

        // Approve pool for asset and collateral
        ERC20(_asset).forceApprove(address(POOL), type(uint256).max);
        ERC20(_collateralToken).forceApprove(address(POOL), type(uint256).max);
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
        POOL.flashLoanSimple(
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
        require(msg.sender == address(POOL), "!pool");
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
        return ERC20(address(asset)).balanceOf(ASSET_A_TOKEN);
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
        uint256 collateralPrice = AAVE_ORACLE.getAssetPrice(collateralToken);
        uint256 assetPrice = AAVE_ORACLE.getAssetPrice(address(asset));

        if (assetPrice == 0) return 0;

        // Both prices are in same denomination (USD), compute ratio
        // Adjust for decimal differences between collateral and asset
        // price = (collateralPrice * 10^assetDecimals * ORACLE_PRICE_SCALE) /
        //         (assetPrice * 10^collateralDecimals)
        return
            (collateralPrice * (10 ** ASSET_DECIMALS) * ORACLE_PRICE_SCALE) /
            (assetPrice * (10 ** COLLATERAL_DECIMALS));
    }

    /*//////////////////////////////////////////////////////////////
                    AAVE PROTOCOL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function _supplyCollateral(uint256 amount) internal override {
        if (amount == 0) return;
        POOL.supply(collateralToken, amount, address(this), REFERRAL_CODE);

        // Enable as collateral (idempotent - safe to call multiple times)
        POOL.setUserUseReserveAsCollateral(collateralToken, true);
    }

    function _withdrawCollateral(uint256 amount) internal override {
        if (amount == 0) return;
        POOL.withdraw(collateralToken, amount, address(this));
    }

    function _borrow(uint256 amount) internal virtual override {
        if (amount == 0) return;
        POOL.borrow(
            address(asset),
            amount,
            VARIABLE_RATE_MODE,
            REFERRAL_CODE,
            address(this)
        );
    }

    function _repay(uint256 amount) internal virtual override {
        if (amount == 0) return;
        POOL.repay(address(asset), amount, VARIABLE_RATE_MODE, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _isSupplyPaused() internal view virtual override returns (bool) {
        return DATA_PROVIDER.getPaused(collateralToken);
    }

    function _isBorrowPaused() internal view virtual override returns (bool) {
        bool isPaused = DATA_PROVIDER.getPaused(address(asset));
        if (isPaused) return true;

        // Also check if borrowing is enabled and not frozen
        (, , , , , , bool borrowingEnabled, , , bool isFrozen) = DATA_PROVIDER
            .getReserveConfigurationData(address(asset));
        return isFrozen || !borrowingEnabled;
    }

    function _isLiquidatable() internal view virtual override returns (bool) {
        (, , , , , uint256 healthFactor) = POOL.getUserAccountData(
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
        (, uint256 supplyCap) = DATA_PROVIDER.getReserveCaps(collateralToken);
        if (supplyCap == 0) return type(uint256).max;

        uint256 currentSupply = DATA_PROVIDER.getATokenTotalSupply(
            collateralToken
        );
        uint256 supplyCapInTokens = supplyCap * (10 ** COLLATERAL_DECIMALS);

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
        (uint256 borrowCap, ) = DATA_PROVIDER.getReserveCaps(address(asset));
        if (borrowCap == 0) {
            // No cap, return available liquidity
            return ERC20(address(asset)).balanceOf(ASSET_A_TOKEN);
        }

        uint256 currentDebt = DATA_PROVIDER.getTotalDebt(address(asset));
        uint256 borrowCapInTokens = borrowCap * (10 ** ASSET_DECIMALS);

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
        (, , uint256 liquidationThreshold, , , , , , , ) = DATA_PROVIDER
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
        return ERC20(A_TOKEN).balanceOf(address(this));
    }

    function balanceOfDebt() public view virtual override returns (uint256) {
        return ERC20(VARIABLE_DEBT_TOKEN).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            REWARDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim all rewards from Aave incentives controller
    function _claimAndSellRewards() internal virtual override {
        address[] memory assets = new address[](2);
        assets[0] = A_TOKEN;
        assets[1] = VARIABLE_DEBT_TOKEN;

        // Claim all rewards to this contract
        REWARDS_CONTROLLER.claimAllRewardsToSelf(assets);
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
