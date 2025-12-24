// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

/**
 * @title IPoolAddressesProvider
 * @notice Defines the basic interface for a Pool Addresses Provider.
 */
interface IPoolAddressesProvider {
    /**
     * @notice Returns the address of the Pool proxy.
     * @return The Pool proxy address
     */
    function getPool() external view returns (address);

    /**
     * @notice Returns the address of the PoolDataProvider proxy.
     * @return The PoolDataProvider proxy address
     */
    function getPoolDataProvider() external view returns (address);

    /**
     * @notice Returns the address of the price oracle.
     * @return The address of the PriceOracle
     */
    function getPriceOracle() external view returns (address);

    /**
     * @notice Returns the address of the ACL manager.
     * @return The address of the ACLManager
     */
    function getACLManager() external view returns (address);

    /**
     * @notice Returns the address of the ACL admin.
     * @return The address of the ACL admin
     */
    function getACLAdmin() external view returns (address);

    /**
     * @notice Returns the id of the Aave market.
     * @return The id of the Aave market
     */
    function getMarketId() external view returns (string memory);

    /**
     * @notice Returns an address by its identifier.
     * @dev The returned address might be an EOA or a contract
     * @param id The id of the address
     * @return The address
     */
    function getAddress(bytes32 id) external view returns (address);
}
