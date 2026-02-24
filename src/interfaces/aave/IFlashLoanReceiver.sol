// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

/**
 * @title IFlashLoanReceiver
 * @notice Defines the interface for an Aave V3 flashloan receiver using flashLoan (multi-asset).
 */
interface IFlashLoanReceiver {
    /**
     * @notice Executes an operation after receiving flash-borrowed assets
     * @param assets The addresses of the flash-borrowed assets
     * @param amounts The amounts of the flash-borrowed assets
     * @param premiums The fees of the flash-borrowed assets
     * @param initiator The address of the flashloan initiator
     * @param params The byte-encoded params passed when initiating the flashloan
     * @return True if the execution succeeds
     */
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);

    /**
     * @notice Returns the address of the PoolAddressesProvider
     */
    function ADDRESSES_PROVIDER() external view returns (address);

    /**
     * @notice Returns the address of the Pool
     */
    function POOL() external view returns (address);
}
