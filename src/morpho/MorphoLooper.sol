// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseLooper} from "../BaseLooper.sol";
import {IMerklDistributor} from "../interfaces/IMerkleDistributor.sol";
import {IMorpho, Id, MarketParams} from "../interfaces/morpho/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "../interfaces/morpho/IMorphoFlashLoanCallback.sol";
import {MorphoOps} from "../libraries/MorphoOps.sol";
import {AuctionSwapper} from "@periphery/swappers/AuctionSwapper.sol";

/**
 * @title MorphoLooper
 * @notice Morpho Blue specific looper implementation.
 *         Exchange conversion logic is inherited from BaseLooper.
 */
contract MorphoLooper is BaseLooper, IMorphoFlashLoanCallback, AuctionSwapper {
    using SafeERC20 for ERC20;
    using MorphoOps for IMorpho;
    using MorphoOps for MarketParams;

    /// @notice The Merkl Distributor contract for claiming rewards
    IMerklDistributor public constant MERKL_DISTRIBUTOR =
        IMerklDistributor(0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae);

    Id public immutable marketId;

    IMorpho public immutable MORPHO;

    bool internal isFlashloanActive;

    MarketParams internal marketParams;

    constructor(
        address _asset,
        string memory _name,
        address _collateralToken,
        address _morpho,
        Id _marketId,
        address _exchange,
        address _governance
    ) BaseLooper(_asset, _name, _collateralToken, _governance, _exchange) {
        MORPHO = IMorpho(_morpho);
        marketId = _marketId;

        marketParams = MORPHO.idToMarketParams(_marketId);
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
        MORPHO.flashLoan(token, amount, data);
        isFlashloanActive = false;
    }

    /// @notice Morpho flashloan callback - CRITICAL SECURITY FUNCTION
    /// @dev Only callable by Morpho contract during flashLoan execution
    function onMorphoFlashLoan(
        uint256 assets,
        bytes calldata data
    ) external override {
        require(msg.sender == address(MORPHO), "!morpho");
        require(isFlashloanActive, "!flashloan active");
        // Delegate to parent's generic handler
        _onFlashloanReceived(assets, data);

        // Morpho already has max approval from constructor, no need to re-approve
    }

    /// @notice Max available flashloan from Morpho
    function maxFlashloan() public view override returns (uint256) {
        return asset.balanceOf(address(MORPHO));
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
        return marketParams.getCollateralPrice();
    }

    /*//////////////////////////////////////////////////////////////
                    MORPHO PROTOCOL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Supply collateral to Morpho Blue market
    /// @dev Calls morpho.supplyCollateral with the configured market params.
    /// @param amount The amount of collateral tokens to supply
    function _supplyCollateral(uint256 amount) internal override {
        MORPHO.supplyCollateral(marketParams, amount);
    }

    /// @notice Withdraw collateral from Morpho Blue market
    /// @dev Calls morpho.withdrawCollateral with the configured market params.
    /// @param amount The amount of collateral tokens to withdraw
    function _withdrawCollateral(uint256 amount) internal override {
        MORPHO.withdrawCollateral(marketParams, amount);
    }

    /// @notice Borrow assets from Morpho Blue market
    /// @dev Override to customize borrow behavior. Calls morpho.borrow with amount (not shares).
    /// @param amount The amount of asset to borrow
    function _borrow(uint256 amount) internal virtual override {
        MORPHO.borrow(marketParams, amount);
    }

    /// @notice Repay borrowed assets to Morpho Blue market
    /// @dev Uses share-based repayment to handle interest accrual properly.
    ///      Calculates shares from amount using expected market balances.
    /// @param amount The amount of asset to repay
    function _repay(uint256 amount) internal virtual override {
        MORPHO.repay(marketId, marketParams, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Check if supplying collateral is paused
    /// @dev Morpho Blue has no pause mechanism, always returns false.
    ///      Override if integrating with a protocol that has pause functionality.
    /// @return Always false for Morpho Blue
    function _isSupplyPaused() internal view virtual override returns (bool) {
        return false;
    }

    /// @notice Check if borrowing is paused
    /// @dev Morpho Blue has no pause mechanism, always returns false.
    ///      Override if integrating with a protocol that has pause functionality.
    /// @return Always false for Morpho Blue
    function _isBorrowPaused() internal view virtual override returns (bool) {
        return false;
    }

    /// @notice Check if the position is at risk of liquidation
    /// @dev Compares current debt against max borrow allowed by LLTV.
    /// @return True if debt exceeds max borrow (position is liquidatable)
    function _isLiquidatable() internal view virtual override returns (bool) {
        return MORPHO.isLiquidatable(marketId, marketParams);
    }

    /// @notice Get the maximum collateral that can be deposited
    /// @dev Morpho Blue has no supply caps, returns max uint256.
    ///      Override if the collateral token has supply limits.
    /// @return Always type(uint256).max for Morpho Blue
    function _maxCollateralDeposit()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return type(uint256).max;
    }

    /// @notice Get the maximum amount that can be borrowed
    /// @dev Returns available liquidity in the Morpho Blue market.
    /// @return The difference between total supply and total borrow
    function _maxBorrowAmount()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return MORPHO.maxBorrowAmount(marketParams);
    }

    /// @notice Get the liquidation loan-to-value threshold (LLTV)
    /// @dev Returns the LLTV from the Morpho market params.
    /// @return The LLTV in WAD (e.g., 0.9e18 = 90%)
    function getLiquidateCollateralFactor()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return marketParams.liquidateCollateralFactor();
    }

    /// @notice Get the collateral balance in Morpho Blue
    /// @dev Reads collateral directly from Morpho position struct.
    /// @return The amount of collateral supplied to Morpho
    function balanceOfCollateral()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return MORPHO.balanceOfCollateral(marketId);
    }

    /// @notice Get the current debt owed to Morpho Blue
    /// @dev Uses expectedBorrowAssets to include accrued interest.
    /// @return The total debt including accrued interest
    function balanceOfDebt() public view virtual override returns (uint256) {
        return MORPHO.balanceOfDebt(marketParams);
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
        _protected = new address[](2);
        _protected[0] = address(asset);
        _protected[1] = collateralToken;
    }

    function kickAuction(
        address _token
    ) external override onlyKeepers returns (uint256) {
        return _kickAuction(_token);
    }
}
