// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

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

        // Zero limits since no token/IRM/price modifications are allowed
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
