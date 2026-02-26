// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";

/// @notice Adds new managed addresses (MarketManagers and/or cTokens) to an
///         existing ProtocolManager.
///
/// @dev Requires the caller to have elevated permissions in the
///      CentralRegistry (timelock or emergency council).
///      Uses zero PeriodLimits since a pause-only ProtocolManager does not
///      need token config, IRM, or price guard adjustment limits.
///
///      Use this script when new cTokens are listed in a market after the
///      ProtocolManager was deployed. Without registering them, per-token
///      pause actions (mint, collateralization, borrow) will revert.
contract AddProtocolManagerMarkets is DeployScript {
    function run(
        address protocolManagerAddress,
        address[] memory newAddresses
    ) external recordEvents {
        ProtocolManager protocolManager = ProtocolManager(protocolManagerAddress);

        // Zero limits — pause-only managers don't need adjustment limits.
        ProtocolManager.PeriodLimits[] memory limits =
            new ProtocolManager.PeriodLimits[](newAddresses.length);

        protocolManager.updateManagementConfig(
            newAddresses,
            limits,
            true
        );
    }
}
