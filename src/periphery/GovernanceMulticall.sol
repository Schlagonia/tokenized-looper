// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {Governance} from "@periphery/utils/Governance.sol";

/// @notice Access-controlled multicall for batching governed configuration.
contract GovernanceMulticall is Governance {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    constructor(address _governance) Governance(_governance) {
        require(_governance != address(0), "!governance");
    }

    receive() external payable {}

    function multicall(
        Call[] calldata calls
    ) external payable onlyGovernance returns (bytes[] memory results) {
        results = new bytes[](calls.length);

        for (uint256 i; i < calls.length; ) {
            Call calldata call = calls[i];
            require(call.target != address(0), "!target");

            (bool success, bytes memory result) = call.target.call{
                value: call.value
            }(call.data);
            if (!success) {
                _revert(result);
            }

            results[i] = result;

            unchecked {
                ++i;
            }
        }
    }

    function _revert(bytes memory reason) internal pure {
        if (reason.length == 0) {
            revert("CALL_FAILED");
        }

        assembly {
            revert(add(reason, 32), mload(reason))
        }
    }
}
