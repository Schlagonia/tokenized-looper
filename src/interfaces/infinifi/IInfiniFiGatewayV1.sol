// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IInfiniFiGatewayV1 {
    function mint(address _to, uint256 _amount) external returns (uint256);

    function mintAndStake(
        address _to,
        uint256 _amount
    ) external returns (uint256);

    function redeem(
        address _to,
        uint256 _amount,
        uint256 _minAssetsOut
    ) external returns (uint256);

    function unstake(address _to, uint256 _amount) external returns (uint256);

    function startUnwinding(uint256 _shares, uint32 _unwindingEpochs) external;

    function withdraw(uint256 _unwindingTimestamp) external;

    function getAddress(string memory _name) external view returns (address);

    function claimRedemption() external;
}
