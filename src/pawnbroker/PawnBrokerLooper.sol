// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseLooper} from "../BaseLooper.sol";
import {IMorpho} from "../interfaces/morpho/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "../interfaces/morpho/IMorphoFlashLoanCallback.sol";
import {PawnBrokerOps} from "../libraries/PawnBrokerOps.sol";
import {IPawnBroker} from "pawn-broker/interfaces/IPawnBroker.sol";

/// @notice Pawn broker-backed looper using an external flashloan source.
contract PawnBrokerLooper is BaseLooper, IMorphoFlashLoanCallback {
    using SafeERC20 for ERC20;
    using PawnBrokerOps for IPawnBroker;

    IPawnBroker public immutable PAWN_BROKER;
    IMorpho public immutable MORPHO;

    bool internal isFlashloanActive;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _morpho,
        address _pawnBroker,
        address _exchange,
        address _governance
    ) BaseLooper(_asset, _name, _collateralToken, _governance, _exchange) {
        require(_morpho != address(0), "!morpho");
        require(_pawnBroker != address(0), "!pawnBroker");

        MORPHO = IMorpho(_morpho);
        PAWN_BROKER = IPawnBroker(_pawnBroker);

        require(PAWN_BROKER.asset() == _asset, "!loanToken");
        require(
            PAWN_BROKER.COLLATERAL_ASSET() == _collateralToken,
            "!collateral"
        );
        require(PAWN_BROKER.BORROWER() == address(this), "!borrower");

        ERC20(_asset).forceApprove(_morpho, type(uint256).max);
        ERC20(_asset).forceApprove(_pawnBroker, type(uint256).max);
        ERC20(_collateralToken).forceApprove(_pawnBroker, type(uint256).max);
    }

    function _executeFlashloan(
        address token,
        uint256 amount,
        bytes memory data
    ) internal virtual override {
        isFlashloanActive = true;
        MORPHO.flashLoan(token, amount, data);
        isFlashloanActive = false;
    }

    function onMorphoFlashLoan(
        uint256 assets,
        bytes calldata data
    ) external virtual override {
        require(msg.sender == address(MORPHO), "!morpho");
        require(isFlashloanActive, "!flashloan active");
        _onFlashloanReceived(assets, data);
    }

    function maxFlashloan() public view virtual override returns (uint256) {
        return asset.balanceOf(address(MORPHO));
    }

    function availableWithdrawLimit(
        address _owner
    ) public view virtual override returns (uint256) {
        if (PAWN_BROKER.paused()) return balanceOfAsset();
        if (PAWN_BROKER.callDeadline() > 0) return balanceOfAsset();

        return super.availableWithdrawLimit(_owner);
    }

    function _getCollateralPrice()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return PAWN_BROKER.getCollateralPrice();
    }

    function _supplyCollateral(uint256 amount) internal virtual override {
        PAWN_BROKER.supplyCollateral(amount);
    }

    function _withdrawCollateral(uint256 amount) internal virtual override {
        PAWN_BROKER.withdrawCollateral(amount);
    }

    function _borrow(uint256 amount) internal virtual override {
        PAWN_BROKER.borrow(amount);
    }

    function _repay(uint256 amount) internal virtual override {
        PAWN_BROKER.repayDebt(amount);
    }

    function _isSupplyPaused() internal view virtual override returns (bool) {
        return PAWN_BROKER.isSupplyPaused();
    }

    function _isBorrowPaused() internal view virtual override returns (bool) {
        return PAWN_BROKER.isBorrowPaused();
    }

    function _isLiquidatable() internal view virtual override returns (bool) {
        return PAWN_BROKER.isLiquidatable();
    }

    function _maxCollateralDeposit()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return type(uint256).max;
    }

    function _maxBorrowAmount()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return PAWN_BROKER.maxBorrowAmount(address(asset));
    }

    function getLiquidateCollateralFactor()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return PAWN_BROKER.liquidateCollateralFactor();
    }

    function balanceOfCollateral()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return PAWN_BROKER.balanceOfCollateral();
    }

    function balanceOfDebt() public view virtual override returns (uint256) {
        return PAWN_BROKER.balanceOfDebt();
    }

    function _claimAndSellRewards() internal pure virtual override {}
}
