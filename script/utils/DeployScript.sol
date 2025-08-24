// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { DeploymentLogger } from "./DeploymentLogger.sol";

contract DeployScript is Script, DeploymentLogger {
    function _delegateCall(address target, bytes memory callData) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = target.delegatecall(callData);
        require(success, string(abi.encodePacked("Delegatecall failed: ", returnData)));
        return returnData;
    }

    /// @notice Modifier to start and stop broadcast for external scripts to be executed as the deployer instead of the contract
    modifier externalScript() {
        vm.stopBroadcast();
        vm.startBroadcast();
        _;
    }
}