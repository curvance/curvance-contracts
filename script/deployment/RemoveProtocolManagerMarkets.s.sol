// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";

/// @notice Removes local ProtocolManager authority for managed addresses.
/// @dev This is the local cleanup half of ProtocolManager retirement. Removing
///      CentralRegistry market permissions alone can be reversed by a later
///      re-grant if local authority remains enabled.
contract RemoveProtocolManagerMarkets is DeployScript {
    function run(
        address protocolManagerAddress,
        address[] memory managedAddresses
    ) external recordEvents {
        ProtocolManager protocolManager = ProtocolManager(protocolManagerAddress);
        ProtocolManager.PeriodLimits[] memory limits =
            new ProtocolManager.PeriodLimits[](managedAddresses.length);

        protocolManager.updateManagementConfig(
            managedAddresses,
            limits,
            false
        );
    }
}
