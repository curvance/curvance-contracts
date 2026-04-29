// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { ProtocolManagerDeployment } from "contracts/architecture/ProtocolManagerDeployment.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Deploys a ProtocolManagerDeployment for atomic market setup.
///
/// @dev POST-DEPLOYMENT REQUIREMENTS:
///      1. The deployed contract MUST be granted market permissions via
///         `CentralRegistry.addMarketPermissions(address)` before it can
///         execute any actions. Requires elevated permissions (timelock or
///         emergency council).
///      2. The `owner` must approve this contract for 77777 of each
///         underlying asset before calling `deployMarket`.
contract DeployProtocolManager_Deployment is DeployScript {
    function run(
        address registry,
        address ownerAddress
    ) external recordEvents {
        ICentralRegistry icr = ICentralRegistry(registry);

        ProtocolManagerDeployment pm = new ProtocolManagerDeployment(
            icr,
            ownerAddress
        );

        emit ContractDeployed(address(pm), "ProtocolManagerDeployment");
    }
}
