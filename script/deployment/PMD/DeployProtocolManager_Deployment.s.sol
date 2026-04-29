// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../../utils/DeployScript.sol";

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

    address constant CENTRAL_REGISTRY = 0x1310f352f1389969Ece6741671c4B919523912fF;
    address constant EMERGENCY_COUNCIL = 0x379D4a8FBc23A8Fd8c2b3738Dbf1fEBe9a64399c;

    function run() external recordEvents {

        ICentralRegistry icr = ICentralRegistry(CENTRAL_REGISTRY);

        ProtocolManagerDeployment pm = new ProtocolManagerDeployment(
            icr,
            EMERGENCY_COUNCIL
        );

        emit ContractDeployed(address(pm), "ProtocolManagerDeployment");
    }
}
