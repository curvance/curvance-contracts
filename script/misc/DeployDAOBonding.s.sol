// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import { CurvanceDAOBonding } from "unused/contracts/misc/CurvanceDAOBonding.sol";

contract DeployDAOBonding is Script {
    // forge script ./script/misc/DeployDAOBonding.s.sol --rpc-url $ETH_NODE_URI_ARB_SEPOLIA
    // forge script ./script/misc/DeployDAOBonding.s.sol --rpc-url $ETH_NODE_URI_ARB_SEPOLIA --broadcast
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: ", deployer);

        vm.startBroadcast(deployerPrivateKey);

        address bonding = address(new CurvanceDAOBonding());
        console.log("bonding: ", bonding);

        vm.stopBroadcast();
    }
}
