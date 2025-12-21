// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { SingleSidedVaultPositionManager } from "contracts/market/position-management/SingleSidedVaultPositionManager.sol";
import { NativeVaultPositionManager } from "contracts/market/position-management/NativeVaultPositionManager.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract AddPlugins is DeployScript {
    struct AvailablePlugins {
        bool simplePositionManager;
        bool singleSidedVaultPositionManager;
        bool nativeVaultPositionManager;
    }

    struct PluginMarket {
        address market;
        string marketName;
        AvailablePlugins plugins;
    }

    function run(
        address registry,
        PluginMarket[] memory markets,
        address wrappedNative
    ) external recordEvents {
        ICentralRegistry icr = ICentralRegistry(registry);
        for(uint256 i; i < markets.length; i++) {
            PluginMarket memory pluginMarket = markets[i];
            MarketManagerIsolated market = MarketManagerIsolated(pluginMarket.market);
            deployPlugins(icr, market, wrappedNative, pluginMarket.marketName, pluginMarket.plugins);
        }
    }

    function deployPlugins(
        ICentralRegistry icr,
        MarketManagerIsolated market,
        address wrappedNative,
        string memory marketName,
        AvailablePlugins memory plugins
    ) public useDeployer {
        if (plugins.nativeVaultPositionManager) {
            NativeVaultPositionManager nativeVaultPositionManager = new NativeVaultPositionManager(
                    icr,
                    address(market),
                    wrappedNative
                );
            MarketManagerIsolated(market).addPositionManager(
                address(nativeVaultPositionManager)
            );
            emit ContractDeployed(
                address(nativeVaultPositionManager),
                string.concat('markets.', marketName, ".plugins.nativeVaultPositionManager")
            );
        }

        if (plugins.simplePositionManager) {
            SimplePositionManager simplePositionManager = new SimplePositionManager(
                    icr,
                    address(market),
                    wrappedNative
                );
            MarketManagerIsolated(market).addPositionManager(
                address(simplePositionManager)
            );
            emit ContractDeployed(
                address(simplePositionManager),
                string.concat('markets.', marketName, ".plugins.simplePositionManager")
            );
        }

        if (plugins.singleSidedVaultPositionManager) {
            SingleSidedVaultPositionManager singleSidedVaultPositionManager = new SingleSidedVaultPositionManager(
                    icr,
                    address(market),
                    wrappedNative
                );
            MarketManagerIsolated(market).addPositionManager(
                address(singleSidedVaultPositionManager)
            );
            emit ContractDeployed(
                address(singleSidedVaultPositionManager),
                string.concat('markets.', marketName, ".plugins.singleSidedVaultPositionManager")
            );
        }
    }
}
