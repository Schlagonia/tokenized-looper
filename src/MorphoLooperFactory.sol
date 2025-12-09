// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {InfinifiMorphoLooper} from "./InfinifiMorphoLooper.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";
import {Id} from "./interfaces/morpho/IMorpho.sol";

contract MorphoLooperFactory {
    event NewStrategy(address indexed strategy, address indexed asset);

    address public immutable emergencyAdmin;
    address public immutable morpho;
    Id public immutable marketId;
    address public immutable gateway;
    address public immutable iusd;
    address public immutable collateralToken;

    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    mapping(address => address) public deployments;

    constructor(
        address _morpho,
        Id _marketId,
        address _gateway,
        address _iusd,
        address _collateralToken,
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin
    ) {
        morpho = _morpho;
        marketId = _marketId;
        gateway = _gateway;
        iusd = _iusd;
        collateralToken = _collateralToken;
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
    }

    function newStrategy(
        address _asset,
        string calldata _name
    ) external virtual returns (address) {
        IStrategyInterface _newStrategy = IStrategyInterface(
            address(
                new InfinifiMorphoLooper(
                    _asset,
                    _name,
                    collateralToken,
                    morpho,
                    marketId,
                    gateway,
                    iusd
                )
            )
        );

        _newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _newStrategy.setKeeper(keeper);
        _newStrategy.setPendingManagement(management);
        _newStrategy.setEmergencyAdmin(emergencyAdmin);

        emit NewStrategy(address(_newStrategy), _asset);

        deployments[_asset] = address(_newStrategy);
        return address(_newStrategy);
    }

    function setAddresses(
        address _management,
        address _performanceFeeRecipient,
        address _keeper
    ) external {
        require(msg.sender == management, "!management");
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
    }

    function isDeployedStrategy(
        address _strategy
    ) external view returns (bool) {
        address _asset = IStrategyInterface(_strategy).asset();
        return deployments[_asset] == _strategy;
    }
}
