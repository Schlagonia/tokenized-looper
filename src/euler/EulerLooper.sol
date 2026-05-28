// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseLooper} from "../BaseLooper.sol";
import {IEVC} from "../interfaces/euler/IEVC.sol";
import {IEVault} from "../interfaces/euler/IEVault.sol";
import {IEulerPriceOracle} from "../interfaces/euler/IEulerPriceOracle.sol";
import {IMerklDistributor} from "../interfaces/IMerkleDistributor.sol";
import {IMorpho} from "../interfaces/morpho/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "../interfaces/morpho/IMorphoFlashLoanCallback.sol";
import {EulerOps} from "../libraries/EulerOps.sol";
import {AuctionSwapper} from "@periphery/swappers/AuctionSwapper.sol";

/**
 * @title EulerLooper
 * @notice Generic EVK looper for any Euler collateral/borrow vault pair.
 */
contract EulerLooper is BaseLooper, IMorphoFlashLoanCallback, AuctionSwapper {
    using SafeERC20 for ERC20;
    using EulerOps for IEVault;

    /// @notice The Merkl Distributor contract for claiming rewards
    IMerklDistributor public constant MERKL_DISTRIBUTOR =
        IMerklDistributor(0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae);

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
        return
            COLLATERAL_VAULT.getCollateralPrice(
                ORACLE,
                UNIT_OF_ACCOUNT,
                address(asset),
                COLLATERAL_UNIT,
                ASSET_UNIT
            );
    }

    /*//////////////////////////////////////////////////////////////
                    EULER PROTOCOL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function _accrueInterest() internal virtual override {
        BORROW_VAULT.accrueInterest();
    }

    function _supplyCollateral(uint256 amount) internal override {
        COLLATERAL_VAULT.supplyCollateral(amount);
    }

    function _withdrawCollateral(uint256 amount) internal override {
        COLLATERAL_VAULT.withdrawCollateral(amount);
    }

    function _borrow(uint256 amount) internal virtual override {
        BORROW_VAULT.borrow(amount);
    }

    function _repay(uint256 amount) internal virtual override {
        BORROW_VAULT.repay(amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _isSupplyPaused() internal view virtual override returns (bool) {
        return COLLATERAL_VAULT.isSupplyPaused();
    }

    function _isBorrowPaused() internal view virtual override returns (bool) {
        return BORROW_VAULT.isBorrowPaused(COLLATERAL_VAULT);
    }

    function _isLiquidatable() internal view virtual override returns (bool) {
        return BORROW_VAULT.isLiquidatable();
    }

    function _maxCollateralDeposit()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return COLLATERAL_VAULT.maxCollateralDeposit();
    }

    function _maxBorrowAmount()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return BORROW_VAULT.maxBorrowAmount();
    }

    function getLiquidateCollateralFactor()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return BORROW_VAULT.liquidateCollateralFactor(COLLATERAL_VAULT);
    }

    function balanceOfCollateral()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return COLLATERAL_VAULT.balanceOfCollateral();
    }

    function balanceOfDebt() public view virtual override returns (uint256) {
        return BORROW_VAULT.balanceOfDebt();
    }

    ////////////////////////////////////////////////////////////////
    //                     REWARDS
    ////////////////////////////////////////////////////////////////

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
}
