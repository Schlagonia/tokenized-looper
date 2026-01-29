// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";

import {SIUSDAprOracle} from "../src/periphery/SIUSDAprOracle.sol";

contract DeploySIUSDAprOracle is Script {
    function run() external {

        vm.startBroadcast();
        SIUSDAprOracle oracle = new SIUSDAprOracle();
        vm.stopBroadcast();

        console.log("Apr : ", oracle.aprAfterDebtChange(0xDBDC1Ef57537E34680B898E1FEBD3D68c7389bCB, 0));

        console.log("Deployed sIUSD APR Oracle:", address(oracle));
    }
}
