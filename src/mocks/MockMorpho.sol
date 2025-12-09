// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Id, MarketParams, Position, Market, Authorization, Signature, IMorpho} from "../interfaces/morpho/IMorpho.sol";
import {MarketParamsLib} from "../libraries/morpho/MarketParamsLib.sol";

/**
 * @notice Minimal stub of Morpho Blue to satisfy BaseMorphoLooper tests.
 *         Only stores market params; most functions are inert or revert.
 */
contract MockMorpho is IMorpho {
    using MarketParamsLib for MarketParams;

    address public ownerAddr;
    address public feeRecipientAddr;

    mapping(Id => MarketParams) internal markets;
    mapping(Id => Market) internal marketData;
    mapping(Id => mapping(address => Position)) internal positions;

    constructor(MarketParams memory params) {
        ownerAddr = msg.sender;
        markets[params.id()] = params;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
        return bytes32(0);
    }

    function isIrmEnabled(address) external pure override returns (bool) {
        return false;
    }

    function isLltvEnabled(uint256) external pure override returns (bool) {
        return false;
    }

    function isAuthorized(
        address authorizer,
        address authorized
    ) external pure override returns (bool) {
        return authorizer == authorized;
    }

    function nonce(address) external pure override returns (uint256) {
        return 0;
    }

    function owner() external view override returns (address) {
        return ownerAddr;
    }

    function feeRecipient() external view override returns (address) {
        return feeRecipientAddr;
    }

    function position(
        Id id,
        address user
    ) external view override returns (Position memory p) {
        p = positions[id][user];
    }

    function market(Id id) external view override returns (Market memory m) {
        m = marketData[id];
    }

    function idToMarketParams(
        Id id
    ) public view override returns (MarketParams memory) {
        MarketParams memory params = markets[id];
        require(params.loanToken != address(0), "market not set");
        return params;
    }

    function extSloads(
        bytes32[] memory slots
    ) external pure override returns (bytes32[] memory results) {
        results = new bytes32[](slots.length);
    }

    /*//////////////////////////////////////////////////////////////
                            MUTATIVE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setOwner(address newOwner) external override {
        require(msg.sender == ownerAddr, "not owner");
        ownerAddr = newOwner;
    }

    function setFeeRecipient(address newFeeRecipient) external override {
        require(msg.sender == ownerAddr, "not owner");
        feeRecipientAddr = newFeeRecipient;
    }

    function setFee(MarketParams memory, uint256) external pure override {
        revert("not implemented");
    }

    function enableIrm(address) external pure override {
        revert("not implemented");
    }

    function enableLltv(uint256) external pure override {
        revert("not implemented");
    }

    function createMarket(MarketParams memory params) external override {
        require(msg.sender == ownerAddr, "not owner");
        markets[params.id()] = params;
    }

    function supply(
        MarketParams memory,
        uint256,
        uint256,
        address,
        bytes memory
    ) external pure override returns (uint256, uint256) {
        revert("not implemented");
    }

    function withdraw(
        MarketParams memory,
        uint256,
        uint256,
        address,
        address
    ) external pure override returns (uint256, uint256) {
        revert("not implemented");
    }

    function borrow(
        MarketParams memory,
        uint256,
        uint256,
        address,
        address
    ) external pure override returns (uint256, uint256) {
        revert("not implemented");
    }

    function repay(
        MarketParams memory,
        uint256,
        uint256,
        address,
        bytes memory
    ) external pure override returns (uint256, uint256) {
        revert("not implemented");
    }

    function supplyCollateral(
        MarketParams memory params,
        uint256 assets,
        address onBehalf,
        bytes memory
    ) external override {
        Position storage p = positions[params.id()][onBehalf];
        p.collateral += uint128(assets);
        marketData[params.id()].totalSupplyAssets += uint128(assets);
    }

    function withdrawCollateral(
        MarketParams memory params,
        uint256 assets,
        address onBehalf,
        address
    ) external override {
        Position storage p = positions[params.id()][onBehalf];
        require(p.collateral >= assets, "insufficient collateral");
        p.collateral -= uint128(assets);
        marketData[params.id()].totalSupplyAssets -= uint128(assets);
    }

    function liquidate(
        MarketParams memory,
        address,
        uint256,
        uint256,
        bytes memory
    ) external pure override returns (uint256, uint256) {
        revert("not implemented");
    }

    function flashLoan(
        address,
        uint256,
        bytes calldata
    ) external pure override {
        revert("not implemented");
    }

    function setAuthorization(address, bool) external pure override {
        revert("not implemented");
    }

    function setAuthorizationWithSig(
        Authorization calldata,
        Signature calldata
    ) external pure override {
        revert("not implemented");
    }

    function accrueInterest(MarketParams memory) external pure override {
        revert("not implemented");
    }
}
