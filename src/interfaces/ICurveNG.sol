// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

interface ICurveNG {
    function exchange(
        int128 _i,
        int128 _j,
        uint256 _dx,
        uint256 _min_dy
    ) external returns (uint256);

    function N_COINS() external view returns (uint256);

    function coins(uint256 _index) external view returns (address);
}
