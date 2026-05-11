// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IOracle} from "../../interfaces/morpho/IOracle.sol";
import {BaseExchange} from "./BaseExchange.sol";

/**
 * @title InventorySwapper
 * @notice Oracle-priced exchange that pays swaps from token inventory already
 *         sitting in this contract.
 * @dev `ORACLE.price()` follows Morpho's convention: one collateral token
 *      quoted in loan token units, scaled by 1e36.
 */
contract InventorySwapper is BaseExchange {
    using SafeERC20 for ERC20;

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    address public immutable LOAN_TOKEN;
    address public immutable COLLATERAL_TOKEN;
    IOracle public immutable ORACLE;

    /// @notice Haircut applied to oracle quotes, in basis points.
    uint256 public slippage;

    event SlippageSet(uint256 slippage);
    event BalancePulled(
        address indexed token,
        address indexed receiver,
        uint256 amount
    );

    constructor(
        address _loanToken,
        address _collateralToken,
        address _oracle,
        uint256 _slippage
    ) {
        require(_loanToken != address(0), "!loanToken");
        require(_collateralToken != address(0), "!collateralToken");
        require(_loanToken != _collateralToken, "!tokens");
        require(_oracle != address(0), "!oracle");

        LOAN_TOKEN = _loanToken;
        COLLATERAL_TOKEN = _collateralToken;
        ORACLE = IOracle(_oracle);

        _setSlippage(_slippage);
    }

    function name() external pure override returns (string memory) {
        return "InventorySwapper";
    }

    function setSlippage(uint256 _slippage) external onlyGovernance {
        _setSlippage(_slippage);
    }

    function pullBalance(
        address token,
        uint256 amount
    ) external onlyGovernance {
        require(token != address(0), "!token");

        uint256 amountToPull = amount == type(uint256).max
            ? ERC20(token).balanceOf(address(this))
            : amount;

        ERC20(token).safeTransfer(msg.sender, amountToPull);
        emit BalancePulled(token, msg.sender, amountToPull);
    }

    function _exchange(
        address from,
        address to,
        uint256 amountIn,
        uint256
    ) internal view override returns (uint256 amountOut) {
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

        amountOut = Math.mulDiv(rawAmountOut, MAX_BPS - slippage, MAX_BPS);
        require(amountOut > 0, "!amountOut");
        require(amountOut <= ERC20(to).balanceOf(address(this)), "!inventory");
    }

    function _setSlippage(uint256 _slippage) internal {
        require(_slippage < MAX_BPS, "slippage");
        slippage = _slippage;
        emit SlippageSet(_slippage);
    }
}
