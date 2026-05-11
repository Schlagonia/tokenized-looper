// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {MarketParams} from "../interfaces/morpho/IMorpho.sol";
import {Governance} from "@periphery/utils/Governance.sol";
import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";

interface IPublicAllocator {
    struct Withdrawal {
        MarketParams marketParams;
        uint128 amount;
    }

    function reallocateTo(
        address vault,
        Withdrawal[] calldata withdrawals,
        MarketParams calldata supplyMarketParams
    ) external payable;
}

interface IKeeperRelayer {
    function tendStrategy(address strategy) external;
}

/// @notice Simple executor that reallocates liquidity, runs arbitrary calls, then tend().
contract LooperKeeper is Governance {
    event AllowedSet(address indexed _address, bool indexed _allowed);

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    modifier onlyKeepers() {
        require(allowed[msg.sender], "not allowed");
        _;
    }

    IPublicAllocator public immutable publicAllocator;
    mapping(address => bool) public allowed;

    constructor(
        address _governance,
        address _publicAllocator
    ) Governance(_governance) {
        require(_publicAllocator != address(0), "allocator=0");
        publicAllocator = IPublicAllocator(_publicAllocator);
        allowed[_governance] = true;
    }

    function setAllowed(
        address _address,
        bool _allowed
    ) external onlyGovernance {
        allowed[_address] = _allowed;
        emit AllowedSet(_address, _allowed);
    }

    function execute(
        address vault,
        IPublicAllocator.Withdrawal[] calldata withdrawals,
        MarketParams calldata supplyMarketParams,
        Call[] calldata calls,
        address strategy,
        uint256 allocatorFee
    ) external payable onlyKeepers {
        require(vault != address(0), "vault=0");
        require(strategy != address(0), "strategy=0");

        uint256 callsValue = _sumValues(calls);
        require(msg.value == allocatorFee + callsValue, "value");

        if (withdrawals.length > 0) {
            publicAllocator.reallocateTo{value: allocatorFee}(
                vault,
                withdrawals,
                supplyMarketParams
            );
        } else {
            require(allocatorFee == 0, "fee");
        }

        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory data) = calls[i].target.call{
                value: calls[i].value
            }(calls[i].data);
            require(ok, string(data));
        }

        IStrategyInterface(strategy).tend();
    }

    function _sumValues(Call[] calldata calls) internal pure returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < calls.length; i++) {
            total += calls[i].value;
        }
        return total;
    }

    function harvestStrategy(
        address _strategyAddress
    ) public onlyKeepers returns (uint256 profit, uint256 loss) {
        (profit, loss) = IStrategyInterface(_strategyAddress).report();
    }

    function tendStrategy(address _strategyAddress) public onlyKeepers {
        IStrategyInterface(_strategyAddress).tend();
    }
}
