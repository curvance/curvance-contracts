// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

/// @notice Removes market permissions from an address in the CentralRegistry.
/// @dev Pair this with any local ProtocolManager authority cleanup needed for
///      the same managed surface.
contract RemoveMarketPermissions is DeployScript {
    function run(
        address registry,
        address addressToRemove
    ) external recordEvents {
        CentralRegistry(registry).removeMarketPermissions(addressToRemove);
    }
}
