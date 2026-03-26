// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IBaseLooper} from "./IBaseLooper.sol";
import {Id} from "./morpho/IMorpho.sol";

interface IMorphoLooper is IBaseLooper {
    function MORPHO() external view returns (address);

    function marketId() external view returns (Id);

    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}
