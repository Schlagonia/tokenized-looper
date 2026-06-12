// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Governance} from "@periphery/utils/Governance.sol";

import {IOracle} from "../interfaces/morpho/IOracle.sol";

/**
 * @title InventorySwapper
 * @notice Oracle-priced exchange that pays swaps from token inventory already
 *         sitting in this contract.
 * @dev `ORACLE.price()` follows Morpho's convention: one collateral token
 *      quoted in loan token units, scaled by 1e36.
 */
contract InventorySwapper is Governance, ReentrancyGuard {
    using SafeERC20 for ERC20;

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    address public immutable LOAN_TOKEN;
    address public immutable COLLATERAL_TOKEN;
    IOracle public immutable ORACLE;

    /// @notice Discount applied to oracle quotes, in basis points.
    uint256 public discount;
    mapping(address => bool) public allowed;
    mapping(address => bool) public allowedForwarders;

    event AllowedSet(address indexed account, bool allowed);
    event AllowedForwarderSet(address indexed forwarder, bool allowed);
    event DiscountSet(uint256 discount);
    event BalanceSwept(
        address indexed token,
        address indexed receiver,
        uint256 amount
    );

    constructor(
        address _loanToken,
        address _collateralToken,
        address _oracle,
        uint256 _discount,
        address _governance
    ) Governance(_governance) {
        require(_loanToken != address(0), "!loanToken");
        require(_collateralToken != address(0), "!collateralToken");
        require(_loanToken != _collateralToken, "!tokens");
        require(_oracle != address(0), "!oracle");

        LOAN_TOKEN = _loanToken;
        COLLATERAL_TOKEN = _collateralToken;
        ORACLE = IOracle(_oracle);

        allowed[msg.sender] = true;
        emit AllowedSet(msg.sender, true);

        _setDiscount(_discount);
    }

    function name() external pure returns (string memory) {
        return "InventorySwapper";
    }

    function setDiscount(uint256 _discount) external onlyGovernance {
        _setDiscount(_discount);
    }

    function setAllowed(
        address account,
        bool isAllowed
    ) external onlyGovernance {
        require(account != address(0), "!account");
        allowed[account] = isAllowed;
        emit AllowedSet(account, isAllowed);
    }

    function setAllowedForwarder(
        address forwarder,
        bool isAllowed
    ) external onlyGovernance {
        require(forwarder != address(0), "!forwarder");
        allowedForwarders[forwarder] = isAllowed;
        emit AllowedForwarderSet(forwarder, isAllowed);
    }

    function sweep(address token, uint256 amount) external onlyGovernance {
        require(token != address(0), "!token");

        uint256 amountToSweep = amount == type(uint256).max
            ? ERC20(token).balanceOf(address(this))
            : amount;

        ERC20(token).safeTransfer(msg.sender, amountToSweep);
        emit BalanceSwept(token, msg.sender, amountToSweep);
    }

    function exchangeWithContext(
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        address context
    ) external nonReentrant returns (uint256 amountOut) {
        require(allowedForwarders[msg.sender], "!forwarder");
        require(allowed[context], "!allowed");

        if (amountIn == 0) return 0;

        ERC20(from).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = _exchangeFor(from, to, amountIn);
        require(amountOut >= amountOutMin, "!amountOut");
        ERC20(to).safeTransfer(msg.sender, amountOut);
    }

    function _exchangeFor(
        address from,
        address to,
        uint256 amountIn
    ) internal view returns (uint256 amountOut) {
        uint256 rawAmountOut;
        uint256 price = ORACLE.price();
        require(price > 0, "!price");

        if (from == LOAN_TOKEN && to == COLLATERAL_TOKEN) {
            rawAmountOut = Math.mulDiv(amountIn, ORACLE_PRICE_SCALE, price);
        } else if (from == COLLATERAL_TOKEN && to == LOAN_TOKEN) {
            rawAmountOut = Math.mulDiv(amountIn, price, ORACLE_PRICE_SCALE);
        } else {
            revert("!pair");
        }

        amountOut = Math.mulDiv(rawAmountOut, MAX_BPS - discount, MAX_BPS);
        require(amountOut > 0, "!amountOut");
        require(amountOut <= ERC20(to).balanceOf(address(this)), "!inventory");
    }

    function _setDiscount(uint256 _discount) internal {
        require(_discount < MAX_BPS, "discount");
        discount = _discount;
        emit DiscountSet(_discount);
    }
}
