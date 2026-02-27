// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Deploys a pause-only ProtocolManager for emergency market
///         management (pause/unpause actions only).
///
/// @dev POST-DEPLOYMENT REQUIREMENT:
///      The deployed ProtocolManager MUST be granted market permissions
///      via `CentralRegistry.addMarketPermissions(protocolManagerAddress)`
///      before it can execute any actions. This call requires elevated
///      permissions (timelock or emergency council) and should be done
///      as a separate step to avoid misconfigurations.
///
///      Without market permissions, all calls from the ProtocolManager
///      to MarketManagerIsolated will revert with `Unauthorized`.
contract DeployProtocolManager_PauseOnly is DeployScript {
    function run(
        address registry,
        address managerAddress,
        address[] memory managedAddresses
    ) external recordEvents {
        ICentralRegistry icr = ICentralRegistry(registry);

        // Pause-only permissions: disable all modification capabilities
        ProtocolManager.PermsConfig memory permsConfig = ProtocolManager.PermsConfig({
            canModifyPriceGuards: false,
            canDisablePriceGuards: false,
            canModifyTokenConfig: false,
            canModifyIRM: false,
            canUnpause: true, // can unpause
            canModifyMintStatus: true, // mint pause
            canModifyCollateralizationStatus: true, // collateralization pause
            canModifyBorrowStatus: true, // borrow pause
            canModifyLiquidationStatus: true, // liquidation pause
            canModifyRedeemStatus: true, // redeem pause
            canModifyTransferStatus: true, // transfer pause
            canModifyPositionManagers: false
        });

        ProtocolManager.PeriodLimits[] memory limits =
            new ProtocolManager.PeriodLimits[](managedAddresses.length);

        // Deploy ProtocolManager
        ProtocolManager protocolManager = new ProtocolManager(
            icr,
            managerAddress,
            permsConfig,
            managedAddresses,
            limits
        );

        emit ContractDeployed(address(protocolManager), "Blockaid-ProtocolManager");
    }
}
