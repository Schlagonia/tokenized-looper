// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseLooper} from "../BaseLooper.sol";
import {IMorpho} from "../interfaces/morpho/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "../interfaces/morpho/IMorphoFlashLoanCallback.sol";
import {IPawnBroker} from "pawn-broker/interfaces/IPawnBroker.sol";

/// @notice Pawn broker-backed looper using an external flashloan source.
contract PawnBrokerLooper is BaseLooper, IMorphoFlashLoanCallback {
    using SafeERC20 for ERC20;

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

    function version() public pure virtual override returns (string memory) {
        return "1.0.0";
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

    function _getCollateralPrice()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return PAWN_BROKER.ORACLE().price();
    }

    function _supplyCollateral(uint256 amount) internal virtual override {
        if (amount == 0) return;
        PAWN_BROKER.postCollateral(amount);
    }

    function _withdrawCollateral(uint256 amount) internal virtual override {
        if (amount == 0) return;
        PAWN_BROKER.withdrawCollateral(amount, address(this));
    }

    function _borrow(uint256 amount) internal virtual override {
        if (amount == 0) return;
        PAWN_BROKER.borrow(amount, address(this));
    }

    function _repay(uint256 amount) internal virtual override {
        if (amount == 0) return;
        PAWN_BROKER.repay(amount);
    }

    function _isSupplyPaused() internal view virtual override returns (bool) {
        return false;
    }

    function _isBorrowPaused() internal view virtual override returns (bool) {
        return PAWN_BROKER.isShutdown() || PAWN_BROKER.calledDebt() > 0;
    }

    function _isLiquidatable() internal view virtual override returns (bool) {
        return !PAWN_BROKER.isHealthy();
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
        uint256 marketBalance = asset.balanceOf(address(PAWN_BROKER));
        uint256 maxDebt = PAWN_BROKER.maxDebt();
        uint256 totalDebt = PAWN_BROKER.totalDebt();

        if (maxDebt <= totalDebt) return 0;

        return Math.min(maxDebt - totalDebt, marketBalance);
    }

    function getLiquidateCollateralFactor()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return PAWN_BROKER.LLTV();
    }

    function balanceOfCollateral()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return PAWN_BROKER.totalCollateral();
    }

    function balanceOfDebt() public view virtual override returns (uint256) {
        return PAWN_BROKER.totalDebt();
    }

    function _claimAndSellRewards() internal pure virtual override {}
}
