// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { SingleSidedVaultPositionManager } from "contracts/market/position-management/SingleSidedVaultPositionManager.sol";
import { NativeVaultPositionManager } from "contracts/market/position-management/NativeVaultPositionManager.sol";
import { BasePositionManager } from "contracts/market/position-management/BasePositionManager.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";

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

            // Verify NativeVaultPositionManager deployment
            _verifyPositionManagerDeployment(
                nativeVaultPositionManager,
                icr,
                address(market),
                wrappedNative
            );

            MarketManagerIsolated(market).addPositionManager(
                address(nativeVaultPositionManager)
            );

            // Verify position manager was added
            require(
                market.isPositionManager(address(nativeVaultPositionManager)),
                "AddPlugins: NativeVaultPositionManager not added to market"
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

            // Verify SimplePositionManager deployment
            _verifyPositionManagerDeployment(
                simplePositionManager,
                icr,
                address(market),
                wrappedNative
            );

            MarketManagerIsolated(market).addPositionManager(
                address(simplePositionManager)
            );

            // Verify position manager was added
            require(
                market.isPositionManager(address(simplePositionManager)),
                "AddPlugins: SimplePositionManager not added to market"
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

            // Verify SingleSidedVaultPositionManager deployment
            _verifyPositionManagerDeployment(
                singleSidedVaultPositionManager,
                icr,
                address(market),
                wrappedNative
            );

            MarketManagerIsolated(market).addPositionManager(
                address(singleSidedVaultPositionManager)
            );

            // Verify position manager was added
            require(
                market.isPositionManager(address(singleSidedVaultPositionManager)),
                "AddPlugins: SingleSidedVaultPositionManager not added to market"
            );

            emit ContractDeployed(
                address(singleSidedVaultPositionManager),
                string.concat('markets.', marketName, ".plugins.singleSidedVaultPositionManager")
            );
        }
    }

    /// @notice Verifies position manager deployment state
    function _verifyPositionManagerDeployment(
        BasePositionManager pm,
        ICentralRegistry expectedRegistry,
        address expectedMarketManager,
        address expectedWrappedNative
    ) internal view {
        // Verify centralRegistry
        require(
            address(pm.centralRegistry()) == address(expectedRegistry),
            "AddPlugins: PositionManager centralRegistry mismatch"
        );

        // Verify marketManager
        require(
            address(pm.marketManager()) == expectedMarketManager,
            "AddPlugins: PositionManager marketManager mismatch"
        );

        // Verify wrappedNative
        require(
            pm.wrappedNative() == expectedWrappedNative,
            "AddPlugins: PositionManager wrappedNative mismatch"
        );

        // Verify ERC165 interface support
        require(
            pm.supportsInterface(type(IPositionManager).interfaceId),
            "AddPlugins: PositionManager does not support IPositionManager interface"
        );
    }
}
