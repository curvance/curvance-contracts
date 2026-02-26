// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

/// @notice Grants market permissions to an address in the CentralRegistry.
///
/// @dev Requires the caller to have elevated permissions in the
///      CentralRegistry (timelock or emergency council).
///
///      This is a required post-deployment step after deploying a
///      ProtocolManager. Without market permissions, all calls from the
///      ProtocolManager to MarketManagerIsolated will revert.
contract AddMarketPermissions is DeployScript {
    function run(
        address registry,
        address newAddress
    ) external recordEvents {
        CentralRegistry(registry).addMarketPermissions(newAddress);
    }
}
