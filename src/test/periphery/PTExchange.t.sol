// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PTExchange} from "../../periphery/PTExchange.sol";
import {IPMarket, IPPrincipalToken, IPYieldToken, IStandardizedYield} from "@periphery/interfaces/Pendle/IPendle.sol";

contract MockERC20 is ERC20 {
    uint8 internal immutable _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract MockSY is IStandardizedYield {
    address[] internal _tokensIn;
    address[] internal _tokensOut;
    address internal _yieldToken;

    constructor(address[] memory tokensIn_) {
        _tokensIn = tokensIn_;
        _tokensOut = tokensIn_;
        _yieldToken = address(0xBEEF);
    }

    function deposit(
        address,
        address,
        uint256,
        uint256
    ) external payable returns (uint256 amountSharesOut) {
        amountSharesOut = 0;
    }

    function redeem(
        address,
        uint256,
        address,
        uint256,
        bool
    ) external returns (uint256 amountTokenOut) {
        amountTokenOut = 0;
    }

    function getTokensIn() external view returns (address[] memory) {
        return _tokensIn;
    }

    function getTokensOut() external view returns (address[] memory) {
        return _tokensOut;
    }

    function yieldToken() external view returns (address) {
        return _yieldToken;
    }
}

contract MockPT is MockERC20, IPPrincipalToken {
    address public immutable override SY;
    address public immutable override YT;
    uint256 public immutable override expiry;

    constructor(address sy_) MockERC20("Mock PT", "mPT", 18) {
        SY = sy_;
        YT = address(0xCAFE);
        expiry = type(uint256).max;
    }

    function isExpired() external pure override returns (bool) {
        return false;
    }
}

contract MockMarket is IPMarket {
    IStandardizedYield internal immutable _sy;
    IPPrincipalToken internal immutable _pt;

    constructor(IStandardizedYield sy_, IPPrincipalToken pt_) {
        _sy = sy_;
        _pt = pt_;
    }

    function readTokens()
        external
        view
        returns (IStandardizedYield, IPPrincipalToken, IPYieldToken)
    {
        return (_sy, _pt, IPYieldToken(address(0)));
    }

    function isExpired() external pure returns (bool) {
        return false;
    }

    function expiry() external pure returns (uint256) {
        return type(uint256).max;
    }
}

contract PTExchangeValidationTest is Test {
    MockERC20 internal asset;
    MockERC20 internal pendleToken;
    MockSY internal sy;
    MockPT internal pt;
    MockMarket internal market;

    function setUp() public {
        asset = new MockERC20("Asset", "AST", 6);
        pendleToken = new MockERC20("Pendle Token", "PND", 6);

        address[] memory tokensIn = new address[](1);
        tokensIn[0] = address(pendleToken);

        sy = new MockSY(tokensIn);
        pt = new MockPT(address(sy));
        market = new MockMarket(
            IStandardizedYield(address(sy)),
            IPPrincipalToken(address(pt))
        );
    }

    function test_constructor_revertsWhenCollateralIsNotMarketPt() public {
        MockERC20 wrongCollateral = new MockERC20("Wrong PT", "wPT", 18);

        vm.expectRevert("!marketPT");
        new PTExchange(
            address(asset),
            address(wrongCollateral),
            address(market),
            address(pendleToken)
        );
    }

    function test_constructor_revertsWhenPendleTokenNotInSyInputs() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "BAD", 6);

        vm.expectRevert("!tokenIn");
        new PTExchange(
            address(asset),
            address(pt),
            address(market),
            address(unsupportedToken)
        );
    }

    function test_constructor_acceptsMarketPtAndValidInputToken() public {
        PTExchange exchange = new PTExchange(
            address(asset),
            address(pt),
            address(market),
            address(pendleToken)
        );

        assertEq(exchange.ASSET(), address(asset), "!asset");
        assertEq(exchange.COLLATERAL(), address(pt), "!collateral");
        assertEq(exchange.PENDLE_MARKET(), address(market), "!market");
        assertEq(
            exchange.PENDLE_TOKEN(),
            address(pendleToken),
            "!pendle token"
        );
    }
}
