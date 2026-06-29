// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployScript} from "../../utils/DeployScript.sol";

import {NativeVaultPositionManager} from "contracts/market/position-management/NativeVaultPositionManager.sol";
import {SimplePositionManager} from "contracts/market/position-management/SimplePositionManager.sol";
import {SingleSidedVaultPositionManager} from "contracts/market/position-management/SingleSidedVaultPositionManager.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Deploys PMD market position managers without registering them.
/// @dev Registration is permissioned and should be queued in Safe batch 1 via
///      MarketManagerIsolated.addPositionManager after the market manager
///      address is known.
contract DeployPMDPlugins is DeployScript {
    struct AvailablePlugins {
        bool simplePositionManager;
        bool vaultPositionManager;
        bool nativeVaultPositionManager;
    }

    function run(
        address centralRegistry,
        string memory marketName,
        address marketManager,
        address wrappedNative,
        AvailablePlugins memory plugins
    ) external recordEvents {
        ICentralRegistry cr = ICentralRegistry(centralRegistry);
        string memory outputKey = string.concat("markets.", marketName, ".plugins.");

        if (plugins.nativeVaultPositionManager) {
            NativeVaultPositionManager nativeVaultPositionManager =
                new NativeVaultPositionManager(cr, marketManager, wrappedNative);

            emit ContractDeployed(
                address(nativeVaultPositionManager),
                string.concat(outputKey, "nativeVaultPositionManager")
            );
        }

        if (plugins.simplePositionManager) {
            SimplePositionManager simplePositionManager =
                new SimplePositionManager(cr, marketManager, wrappedNative);

            emit ContractDeployed(
                address(simplePositionManager),
                string.concat(outputKey, "simplePositionManager")
            );
        }

        if (plugins.vaultPositionManager) {
            SingleSidedVaultPositionManager vaultPositionManager =
                new SingleSidedVaultPositionManager(cr, marketManager, wrappedNative);

            emit ContractDeployed(
                address(vaultPositionManager),
                string.concat(outputKey, "vaultPositionManager")
            );
        }
    }
}
