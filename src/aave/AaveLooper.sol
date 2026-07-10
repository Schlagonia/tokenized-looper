// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseLooper} from "../BaseLooper.sol";
import {IPool} from "../interfaces/aave/IPool.sol";
import {IPoolDataProvider} from "../interfaces/aave/IPoolDataProvider.sol";
import {IPoolAddressesProvider} from "../interfaces/aave/IPoolAddressesProvider.sol";
import {IRewardsController} from "../interfaces/aave/IRewardsController.sol";
import {IAToken} from "../interfaces/aave/IAToken.sol";
import {IMerklDistributor} from "../interfaces/IMerkleDistributor.sol";
import {IMorpho} from "../interfaces/morpho/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "../interfaces/morpho/IMorphoFlashLoanCallback.sol";
import {AaveOps} from "../libraries/AaveOps.sol";
import {AuctionSwapper} from "@periphery/swappers/AuctionSwapper.sol";

/**
 * @title AaveLooper
 * @notice Aave V3 specific looper implementation.
 *         Exchange conversion logic is inherited from BaseLooper.
 */
contract AaveLooper is BaseLooper, IMorphoFlashLoanCallback, AuctionSwapper {
    using SafeERC20 for ERC20;
    using AaveOps for address;
    using AaveOps for IPoolAddressesProvider;
    using AaveOps for IPoolDataProvider;
    using AaveOps for IRewardsController;

    /// @notice The Merkl Distributor contract for claiming rewards
    IMerklDistributor public constant MERKL_DISTRIBUTOR =
        IMerklDistributor(0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae);

    /// @notice Morpho flashloan provider
    IMorpho public immutable MORPHO;

    /// @notice Aave V3 Pool
    address public immutable POOL;

    /// @notice Aave V3 Data Provider
    IPoolDataProvider public immutable DATA_PROVIDER;

    /// @notice Aave V3 Pool Addresses Provider
    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

    /// @notice Aave V3 Rewards Controller
    IRewardsController public immutable REWARDS_CONTROLLER;

    /// @notice aToken address for collateral
    address public immutable A_TOKEN;

    /// @notice aToken address for asset
    address internal immutable ASSET_A_TOKEN;

    /// @notice Variable debt token address for the asset (borrow token)
    address public immutable VARIABLE_DEBT_TOKEN;

    /// @notice True when the pool exposes Aave virtual reserve balances
    bool internal immutable USE_VIRTUAL_BALANCE;

    /// @notice Cached decimals for collateral token
    uint256 internal immutable COLLATERAL_DECIMALS;

    /// @notice Cached decimals for asset token
    uint256 internal immutable ASSET_DECIMALS;

    /// @notice Flashloan reentrancy guard
    bool internal isFlashloanActive;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _addressesProvider,
        address _morpho,
        uint8 _eModeCategoryId,
        address _exchange,
        address _governance
    ) BaseLooper(_asset, _name, _collateralToken, _governance, _exchange) {
        MORPHO = IMorpho(_morpho);
        ADDRESSES_PROVIDER = IPoolAddressesProvider(_addressesProvider);
        POOL = ADDRESSES_PROVIDER.getPool();
        DATA_PROVIDER = IPoolDataProvider(
            ADDRESSES_PROVIDER.getPoolDataProvider()
        );

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

        (bool _useVirtualBalance, ) = POOL.staticcall(
            abi.encodeWithSelector(
                IPool.getVirtualUnderlyingBalance.selector,
                _asset
            )
        );
        USE_VIRTUAL_BALANCE = _useVirtualBalance;

        // Cache decimals to avoid repeated external calls
        COLLATERAL_DECIMALS = ERC20(_collateralToken).decimals();
        ASSET_DECIMALS = ERC20(_asset).decimals();

        // Set E-Mode category for better capital efficiency on correlated assets
        IPool(POOL).setUserEMode(_eModeCategoryId);

        // Approve pool for asset and collateral
        ERC20(_asset).forceApprove(POOL, type(uint256).max);
        ERC20(_collateralToken).forceApprove(POOL, type(uint256).max);
        // Approve Morpho for flashloan repayment
        ERC20(_asset).forceApprove(_morpho, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        FLASHLOAN IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute flashloan through Morpho
    function _executeFlashloan(
        address token,
        uint256 amount,
        bytes memory data
    ) internal override {
        isFlashloanActive = true;
        MORPHO.flashLoan(token, amount, data);
        isFlashloanActive = false;
    }

    /// @notice Morpho flashloan callback - CRITICAL SECURITY FUNCTION
    /// @dev Only callable by Morpho during flashLoan execution
    function onMorphoFlashLoan(
        uint256 assets,
        bytes calldata data
    ) external override {
        require(msg.sender == address(MORPHO), "!morpho");
        require(isFlashloanActive, "!flashloan active");

        _onFlashloanReceived(assets, data);
    }

    /// @notice Max available flashloan from Morpho
    function maxFlashloan() public view override returns (uint256) {
        return asset.balanceOf(address(MORPHO));
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
        return
            ADDRESSES_PROVIDER.getCollateralPrice(
                collateralToken,
                address(asset),
                ASSET_DECIMALS,
                COLLATERAL_DECIMALS
            );
    }

    /*//////////////////////////////////////////////////////////////
                    AAVE PROTOCOL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function _supplyCollateral(uint256 amount) internal override {
        POOL.supply(collateralToken, amount);
    }

    function _withdrawCollateral(uint256 amount) internal override {
        POOL.withdraw(collateralToken, amount);
    }

    function _borrow(uint256 amount) internal virtual override {
        POOL.borrow(address(asset), amount);
    }

    function _repay(uint256 amount) internal virtual override {
        POOL.repay(address(asset), amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _isSupplyPaused() internal view virtual override returns (bool) {
        return DATA_PROVIDER.isSupplyPaused(collateralToken);
    }

    function _isBorrowPaused() internal view virtual override returns (bool) {
        return DATA_PROVIDER.isBorrowPaused(address(asset));
    }

    function _isLiquidatable() internal view virtual override returns (bool) {
        return POOL.isLiquidatable();
    }

    function _maxCollateralDeposit()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return
            DATA_PROVIDER.maxCollateralDeposit(
                collateralToken,
                COLLATERAL_DECIMALS
            );
    }

    function _maxBorrowAmount()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return
            POOL.maxBorrowAmount(
                DATA_PROVIDER,
                address(asset),
                ASSET_A_TOKEN,
                USE_VIRTUAL_BALANCE,
                ASSET_DECIMALS
            );
    }

    function getLiquidateCollateralFactor()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return POOL.liquidateCollateralFactor(DATA_PROVIDER, collateralToken);
    }

    function balanceOfCollateral()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return A_TOKEN.balanceOfCollateral();
    }

    function balanceOfDebt() public view virtual override returns (uint256) {
        return VARIABLE_DEBT_TOKEN.balanceOfDebt();
    }

    /*//////////////////////////////////////////////////////////////
                            REWARDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim all rewards from Aave incentives controller
    function claimRewards() external virtual onlyKeepers {
        REWARDS_CONTROLLER.claimRewards(A_TOKEN, VARIABLE_DEBT_TOKEN);
    }

    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external {
        MERKL_DISTRIBUTOR.claim(users, tokens, amounts, proofs);
    }

    function _claimAndSellRewards() internal virtual override {}

    function setAuction(address _auction) external onlyManagement {
        _setAuction(_auction);
    }

    function setEModeCategory(uint8 _eModeCategoryId) external onlyManagement {
        IPool(POOL).setUserEMode(_eModeCategoryId);
    }

    function protectedTokens()
        public
        view
        virtual
        override
        returns (address[] memory _protected)
    {
        _protected = new address[](5);
        _protected[0] = address(asset);
        _protected[1] = collateralToken;
        _protected[2] = A_TOKEN;
        _protected[3] = ASSET_A_TOKEN;
        _protected[4] = VARIABLE_DEBT_TOKEN;
    }

    function kickAuction(
        address _token
    ) external override onlyKeepers returns (uint256) {
        return _kickAuction(_token);
    }
}
