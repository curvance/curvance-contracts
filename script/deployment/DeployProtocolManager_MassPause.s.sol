// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { ProtocolManagerMassPause } from "contracts/architecture/ProtocolManagerMassPause.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Deploys a ProtocolManagerMassPause for emergency pause operations.
///
/// @dev POST-DEPLOYMENT REQUIREMENT:
///      The deployed contract MUST be granted market permissions via
///      `CentralRegistry.addMarketPermissions(address)` before it can
///      execute any pause/unpause actions. Requires elevated permissions
///      (timelock or emergency council).
contract DeployProtocolManager_MassPause is DeployScript {
    function run(
        address registry,
        address ownerAddress
    ) external recordEvents {
        ICentralRegistry icr = ICentralRegistry(registry);

        ProtocolManagerMassPause pm = new ProtocolManagerMassPause(
            icr,
            ownerAddress
        );

        emit ContractDeployed(address(pm), "ProtocolManagerMassPause");
    }
}
