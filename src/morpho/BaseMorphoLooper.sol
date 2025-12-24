// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseLooper} from "../BaseLooper.sol";
import {IMorpho, Id, MarketParams, Position} from "../interfaces/morpho/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "../interfaces/morpho/IMorphoFlashLoanCallback.sol";
import {IOracle} from "../interfaces/morpho/IOracle.sol";
import {MarketParamsLib} from "../libraries/morpho/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../libraries/morpho/periphery/MorphoBalancesLib.sol";
import {MorphoLib} from "../libraries/morpho/periphery/MorphoLib.sol";
import {SharesMathLib} from "../libraries/morpho/SharesMathLib.sol";
import {IMerklDistributor} from "../interfaces/IMerkleDistributor.sol";
import {AuctionSwapper} from "@periphery/swappers/AuctionSwapper.sol";

/**
 * @title BaseMorphoLooper
 * @notice Morpho Blue specific implementation of BaseLooper.
 *         Implements the flashloan callback and protocol-specific operations.
 *         All generic flashloan logic and calculations live in BaseLooper.
 */
abstract contract BaseMorphoLooper is
    BaseLooper,
    IMorphoFlashLoanCallback,
    AuctionSwapper
{
    using SafeERC20 for ERC20;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using MorphoLib for IMorpho;

    /// @notice The Merkl Distributor contract for claiming rewards
    IMerklDistributor public constant MERKL_DISTRIBUTOR =
        IMerklDistributor(0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae);

    Id public immutable marketId;

    IMorpho public immutable morpho;

    MarketParams internal marketParams;

    bool internal isFlashloanActive;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId
    ) BaseLooper(_asset, _name, _collateralToken) {
        morpho = IMorpho(_morpho);
        marketId = _marketId;

        marketParams = morpho.idToMarketParams(_marketId);
        require(marketParams.loanToken == _asset, "!loanToken");
        require(
            marketParams.collateralToken == _collateralToken,
            "!collateral"
        );

        ERC20(_asset).forceApprove(_morpho, type(uint256).max);
        ERC20(_collateralToken).forceApprove(_morpho, type(uint256).max);
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
        morpho.flashLoan(token, amount, data);
        isFlashloanActive = false;
    }

    /// @notice Morpho flashloan callback - CRITICAL SECURITY FUNCTION
    /// @dev Only callable by Morpho contract during flashLoan execution
    function onMorphoFlashLoan(
        uint256 assets,
        bytes calldata data
    ) external override {
        require(msg.sender == address(morpho), "!morpho");
        require(isFlashloanActive, "flashloan active");
        // Delegate to parent's generic handler
        _onFlashloanReceived(assets, data);

        // Morpho already has max approval from constructor, no need to re-approve
    }

    /// @notice Max available flashloan from Morpho
    function maxFlashloan() public view override returns (uint256) {
        return asset.balanceOf(address(morpho));
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Get oracle price (loan token value per 1 collateral token, 1e36 scale)
    /// @dev Returns raw oracle price to preserve precision. Callers must divide by ORACLE_PRICE_SCALE.
    function _getCollateralPrice()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return IOracle(marketParams.oracle).price();
    }

    /*//////////////////////////////////////////////////////////////
                    MORPHO PROTOCOL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function _supplyCollateral(uint256 amount) internal override {
        if (amount == 0) return;
        morpho.supplyCollateral(marketParams, amount, address(this), "");
    }

    function _withdrawCollateral(uint256 amount) internal override {
        if (amount == 0) return;
        morpho.withdrawCollateral(
            marketParams,
            amount,
            address(this),
            address(this)
        );
    }

    function _borrow(uint256 amount) internal virtual override {
        if (amount == 0) return;
        morpho.borrow(marketParams, amount, 0, address(this), address(this));
    }

    function _repay(uint256 amount) internal virtual override {
        if (amount == 0) return;
        (
            ,
            ,
            uint256 totalBorrowAssets,
            uint256 totalBorrowShares
        ) = MorphoBalancesLib.expectedMarketBalances(morpho, marketParams);

        uint256 shares = Math.min(
            SharesMathLib.toSharesDown(
                amount,
                totalBorrowAssets,
                totalBorrowShares
            ),
            morpho.borrowShares(marketId, address(this))
        );

        morpho.repay(marketParams, 0, shares, address(this), "");
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _isSupplyPaused() internal view virtual override returns (bool) {
        return false;
    }

    function _isBorrowPaused() internal view virtual override returns (bool) {
        return false;
    }

    function _isLiquidatable() internal view virtual override returns (bool) {
        Position memory p = morpho.position(marketId, address(this));
        if (p.borrowShares == 0) return false;

        uint256 collateralValue = (uint256(p.collateral) *
            IOracle(marketParams.oracle).price()) / ORACLE_PRICE_SCALE;
        uint256 maxBorrow = (collateralValue * marketParams.lltv) / WAD;

        return balanceOfDebt() > maxBorrow;
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
        (uint256 totalSupplyAssets, , uint256 totalBorrowAssets, ) = morpho
            .expectedMarketBalances(marketParams);
        return
            totalSupplyAssets > totalBorrowAssets
                ? totalSupplyAssets - totalBorrowAssets
                : 0;
    }

    function getLiquidateCollateralFactor()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return marketParams.lltv;
    }

    function balanceOfCollateral()
        public
        view
        virtual
        override
        returns (uint256)
    {
        Position memory p = morpho.position(marketId, address(this));
        return p.collateral;
    }

    function balanceOfDebt() public view virtual override returns (uint256) {
        return morpho.expectedBorrowAssets(marketParams, address(this));
    }

    ////////////////////////////////////////////////////////////////
    //                     REWARDS
    ////////////////////////////////////////////////////////////////

    /**
     * @notice Claims rewards from Merkl distributor
     * @param users Recipients of tokens
     * @param tokens ERC20 tokens being claimed
     * @param amounts Amounts of tokens that will be sent to the corresponding users
     * @param proofs Array of Merkle proofs verifying the claims
     */
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external {
        MERKL_DISTRIBUTOR.claim(users, tokens, amounts, proofs);
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
