// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Deploys a ProtocolManager with caller-supplied permissions and
///         managed-address period limits.
///
/// @dev POST-DEPLOYMENT REQUIREMENT:
///      The deployed ProtocolManager MUST be granted market permissions
///      via `CentralRegistry.addMarketPermissions(protocolManagerAddress)`
///      before it can execute market actions. This call requires elevated
///      permissions (timelock or emergency council) and should be done
///      as a separate step to avoid misconfigurations.
///
///      `managedAddresses` and `limits` must have matching lengths; the
///      ProtocolManager constructor validates that relationship and each
///      supplied period limit.
contract DeployProtocolManager is DeployScript {
    function run(
        address registry,
        address managerAddress,
        ProtocolManager.PermsConfig memory permsConfig,
        address[] memory managedAddresses,
        ProtocolManager.PeriodLimits[] memory limits,
        string memory deploymentName
    ) external recordEvents {
        ICentralRegistry icr = ICentralRegistry(registry);

        ProtocolManager protocolManager = new ProtocolManager(
            icr,
            managerAddress,
            permsConfig,
            managedAddresses,
            limits
        );

        emit ContractDeployed(address(protocolManager), deploymentName);
    }
}
