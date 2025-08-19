// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";

import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { VaultZapper } from "contracts/plugins/market/VaultZapper.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract AddPlugins is Script, DeploymentLogger {
    struct AvailablePlugins {
        bool simplePositionManager;
        bool simpleZapper;
        bool vaultZapper;
    }

    struct PluginMarkets {
        address market;
        string marketName;
        AvailablePlugins plugins;
    }

    function run(
        address registry,
        PluginMarkets[] memory markets,
        address wrappedNative
    ) external recordEvents {
        ICentralRegistry icr = ICentralRegistry(registry);
        for(uint256 i; i < markets.length; i++) {
            PluginMarkets memory pluginMarket = markets[i];
            MarketManagerIsolated market = MarketManagerIsolated(pluginMarket.market);
            _deployPlugins(icr, market, wrappedNative, pluginMarket.marketName, pluginMarket.plugins);
        }
    }

    function _deployPlugins(
        ICentralRegistry icr,
        MarketManagerIsolated market,
        address wrappedNative,
        string memory marketName,
        AvailablePlugins memory plugins
    ) internal {
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
                string.concat(marketName, ".plugins.simplePositionManager")
            );
        }

        if (plugins.simpleZapper) {
            SimpleZapper simpleZapper = new SimpleZapper(icr, wrappedNative);
            emit ContractDeployed(
                address(simpleZapper),
                string.concat(marketName, ".plugins.simpleZapper")
            );
        }

        if (plugins.vaultZapper) {
            VaultZapper vaultZapper = new VaultZapper(icr, wrappedNative);
            emit ContractDeployed(
                address(vaultZapper),
                string.concat(marketName, ".plugins.vaultZapper")
            );
        }
    }
}
