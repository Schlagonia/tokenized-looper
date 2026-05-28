// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseLooper} from "../BaseLooper.sol";
import {IEVC} from "../interfaces/euler/IEVC.sol";
import {IEVault} from "../interfaces/euler/IEVault.sol";
import {IEulerPriceOracle} from "../interfaces/euler/IEulerPriceOracle.sol";
import {IMorpho} from "../interfaces/morpho/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "../interfaces/morpho/IMorphoFlashLoanCallback.sol";
import {AuctionSwapper} from "@periphery/swappers/AuctionSwapper.sol";

/**
 * @title EulerLooper
 * @notice Generic EVK looper for any Euler collateral/borrow vault pair.
 */
contract EulerLooper is BaseLooper, IMorphoFlashLoanCallback, AuctionSwapper {
    using SafeERC20 for ERC20;

    uint32 internal constant OP_DEPOSIT = 1 << 0;
    uint32 internal constant OP_WITHDRAW = 1 << 2;
    uint32 internal constant OP_BORROW = 1 << 6;
    uint32 internal constant OP_REPAY = 1 << 7;
    uint32 internal constant OP_TOUCH = 1 << 13;

    IEVault public immutable COLLATERAL_VAULT;
    IEVault public immutable BORROW_VAULT;
    IEVC public immutable EVC;
    IMorpho public immutable MORPHO;
    IEulerPriceOracle public immutable ORACLE;
    address public immutable UNIT_OF_ACCOUNT;

    uint256 internal immutable COLLATERAL_UNIT;
    uint256 internal immutable ASSET_UNIT;

    bool internal isFlashloanActive;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _collateralVault,
        address _borrowVault,
        address _morpho,
        address _exchange,
        address _governance
    ) BaseLooper(_asset, _name, _collateralToken, _governance, _exchange) {
        require(_collateralVault != address(0), "!collateralVault");
        require(_borrowVault != address(0), "!borrowVault");
        require(_morpho != address(0), "!morpho");

        COLLATERAL_VAULT = IEVault(_collateralVault);
        BORROW_VAULT = IEVault(_borrowVault);
        MORPHO = IMorpho(_morpho);

        require(COLLATERAL_VAULT.asset() == _collateralToken, "!collateral");
        require(BORROW_VAULT.asset() == _asset, "!asset");
        require(BORROW_VAULT.LTVBorrow(_collateralVault) > 0, "!ltv");

        address evc = BORROW_VAULT.EVC();
        require(evc != address(0) && evc == COLLATERAL_VAULT.EVC(), "!evc");
        EVC = IEVC(evc);
        ORACLE = IEulerPriceOracle(BORROW_VAULT.oracle());
        UNIT_OF_ACCOUNT = BORROW_VAULT.unitOfAccount();

        COLLATERAL_UNIT = 10 ** ERC20(_collateralToken).decimals();
        ASSET_UNIT = 10 ** ERC20(_asset).decimals();
        EVC.enableCollateral(address(this), _collateralVault);
        EVC.enableController(address(this), _borrowVault);

        ERC20(_asset).forceApprove(_borrowVault, type(uint256).max);
        ERC20(_asset).forceApprove(_morpho, type(uint256).max);
        ERC20(_collateralToken).forceApprove(
            _collateralVault,
            type(uint256).max
        );
    }

    /*//////////////////////////////////////////////////////////////
                        FLASHLOAN IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    function _executeFlashloan(
        address token,
        uint256 amount,
        bytes memory data
    ) internal override {
        isFlashloanActive = true;
        MORPHO.flashLoan(token, amount, data);
        isFlashloanActive = false;
    }

    function onMorphoFlashLoan(
        uint256 assets,
        bytes calldata data
    ) external override {
        require(msg.sender == address(MORPHO), "!morpho");
        require(isFlashloanActive, "!flashloan active");

        _onFlashloanReceived(assets, data);
    }

    function maxFlashloan() public view override returns (uint256) {
        return asset.balanceOf(address(MORPHO));
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    function _getCollateralPrice()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        // Euler prices collateral by the collateral vault share token, not by
        // the vault's underlying asset. Convert one whole underlying collateral
        // token into the corresponding amount of collateral vault shares first.
        uint256 collateralShares = COLLATERAL_VAULT.convertToShares(
            COLLATERAL_UNIT
        );

        // Euler's solvency math prices both collateral and liabilities into the
        // borrow vault's unit of account.
        uint256 collateralValue = _quoteToUnitOfAccount(
            collateralShares,
            address(COLLATERAL_VAULT)
        );
        uint256 assetValue = _quoteToUnitOfAccount(ASSET_UNIT, address(asset));

        if (assetValue == 0) return 0;

        // Convert the unit-of-account ratio into BaseLooper's format:
        // asset-per-underlying-collateral scaled by 1e36. Apply the 1e36
        // scale before dividing by the asset value to avoid dropping precision
        // for low-priced collateral.
        uint256 scaledCollateralValue = Math.mulDiv(
            collateralValue,
            ORACLE_PRICE_SCALE,
            COLLATERAL_UNIT
        );
        return Math.mulDiv(scaledCollateralValue, ASSET_UNIT, assetValue);
    }

    function _quoteToUnitOfAccount(
        uint256 amount,
        address base
    ) internal view returns (uint256) {
        // If the asset is already the unit of account, no oracle call is needed.
        return
            base == UNIT_OF_ACCOUNT
                ? amount
                : ORACLE.getQuote(amount, base, UNIT_OF_ACCOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                    EULER PROTOCOL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function _accrueInterest() internal virtual override {
        if (!_isOperationDisabled(BORROW_VAULT, OP_TOUCH)) BORROW_VAULT.touch();
    }

    function _supplyCollateral(uint256 amount) internal override {
        if (amount == 0) return;
        COLLATERAL_VAULT.deposit(amount, address(this));
    }

    function _withdrawCollateral(uint256 amount) internal override {
        if (amount == 0) return;
        COLLATERAL_VAULT.withdraw(amount, address(this), address(this));
    }

    function _borrow(uint256 amount) internal virtual override {
        if (amount == 0) return;
        BORROW_VAULT.borrow(amount, address(this));
    }

    function _repay(uint256 amount) internal virtual override {
        if (amount == 0) return;

        uint256 debt = balanceOfDebt();
        if (debt == 0) return;

        BORROW_VAULT.repay(
            amount >= debt ? type(uint256).max : amount,
            address(this)
        );
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _isSupplyPaused() internal view virtual override returns (bool) {
        if (_isOperationDisabled(COLLATERAL_VAULT, OP_DEPOSIT)) return true;
        return COLLATERAL_VAULT.maxDeposit(address(this)) == 0;
    }

    function _isBorrowPaused() internal view virtual override returns (bool) {
        if (_isOperationDisabled(BORROW_VAULT, OP_BORROW)) return true;
        return
            BORROW_VAULT.LTVBorrow(address(COLLATERAL_VAULT)) == 0 ||
            _maxBorrowAmount() == 0;
    }

    function _isLiquidatable() internal view virtual override returns (bool) {
        if (balanceOfDebt() == 0) return false;

        (uint256 collateralValue, uint256 liabilityValue) = BORROW_VAULT
            .accountLiquidity(address(this), true);

        return liabilityValue > collateralValue;
    }

    function _maxCollateralDeposit()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        (uint16 encodedSupplyCap, ) = COLLATERAL_VAULT.caps();
        if (encodedSupplyCap == 0) return type(uint256).max;

        return COLLATERAL_VAULT.maxDeposit(address(this));
    }

    function _maxBorrowAmount()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        uint256 cash = BORROW_VAULT.cash();

        (, uint16 encodedBorrowCap) = BORROW_VAULT.caps();
        uint256 borrowCap = _resolveAmountCap(encodedBorrowCap);
        if (borrowCap == type(uint256).max) return cash;

        uint256 borrows = BORROW_VAULT.totalBorrows();
        uint256 capRemaining = borrowCap > borrows ? borrowCap - borrows : 0;

        return Math.min(cash, capRemaining);
    }

    function getLiquidateCollateralFactor()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return
            uint256(BORROW_VAULT.LTVLiquidation(address(COLLATERAL_VAULT))) *
            1e14;
    }

    function balanceOfCollateral()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return
            COLLATERAL_VAULT.convertToAssets(
                COLLATERAL_VAULT.balanceOf(address(this))
            );
    }

    function balanceOfDebt() public view virtual override returns (uint256) {
        return BORROW_VAULT.debtOf(address(this));
    }

    ////////////////////////////////////////////////////////////////
    //                     REWARDS
    ////////////////////////////////////////////////////////////////

    function _claimAndSellRewards() internal virtual override {}

    function setAuction(address _auction) external onlyManagement {
        _setAuction(_auction);
    }

    function setUseAuction(bool _useAuction) external onlyManagement {
        _setUseAuction(_useAuction);
    }

    function protectedTokens()
        public
        view
        virtual
        override
        returns (address[] memory _protected)
    {
        _protected = new address[](4);
        _protected[0] = address(asset);
        _protected[1] = collateralToken;
        _protected[2] = address(COLLATERAL_VAULT);
        _protected[3] = address(BORROW_VAULT);
    }

    function kickAuction(
        address _token
    ) external override onlyKeepers returns (uint256) {
        return _kickAuction(_token);
    }

    function _isOperationDisabled(
        IEVault vault,
        uint32 operation
    ) internal view returns (bool) {
        (address hookTarget, uint32 hookedOps) = vault.hookConfig();
        return (hookedOps & operation) != 0 && hookTarget.code.length == 0;
    }

    function _resolveAmountCap(
        uint16 encodedCap
    ) internal pure returns (uint256) {
        if (encodedCap == 0) return type(uint256).max;

        uint256 exponent = encodedCap & 63;
        uint256 mantissa = encodedCap >> 6;

        return (mantissa * (10 ** exponent)) / 100;
    }
}
