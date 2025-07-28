// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { VaultZapper } from "contracts/plugins/market/VaultZapper.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract DeployMarkets is Script {
    struct DynamicInterestRateConfig {
        uint256 baseRatePerYear;
        uint256 vertexRatePerYear;
        uint256 vertexUtilStart;
        uint256 adjustmentRate;
        uint256 adjustmentVelocity;
        uint256 vertexMultiplierMax;
        uint256 decayRate;
    }

    struct AvailablePlugins {
        bool simplePositionManager;
        bool simpleZapper;
        bool vaultZapper;
    }

    struct ListConfig {
        address asset;
        bool canBorrow;
        MarketManagerIsolated.TokenConfig tokenConfig;
        DynamicInterestRateConfig interestConfig;
    }

    event ContractDeployed(address contractAddress, string contractName);
    event ContractMetadata(string jsonIndex, string key, bool value);

    DeploymentLogger logger;

    function run(
        address centralRegistry,
        string[] memory names,
        ListConfig[][] memory tokens,
        uint256[] memory interestFees,
        address wrappedNative,
        AvailablePlugins[] memory plugins
    ) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        CentralRegistry registry = CentralRegistry(centralRegistry);
        ICentralRegistry icr = ICentralRegistry(centralRegistry);
        OracleManager router = OracleManager(registry.oracleManager());

        for (uint256 i = 0; i < names.length; i++) {
            string memory name = names[i];
            ListConfig[] memory tokens = tokens[i];

            MarketManagerIsolated market = new MarketManagerIsolated(icr);
            registry.addMarketManager(address(market), interestFees[i]);
            emit ContractDeployed(
                address(market),
                string.concat(name, ".address")
            );
            emit ContractMetadata(name, "isMarket", true);

            _deployPlugins(icr, market, wrappedNative, name, plugins[i]);

            address[] memory cTokens = _deployCTokens(
                tokens,
                router,
                name,
                market,
                icr
            );

            market.listTokens(cTokens[0], cTokens[1]);
            market.updateTokenConfig(tokens[0].tokenConfig);
            market.updateTokenConfig(tokens[1].tokenConfig);
        }

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }

    function _deployCTokens(
        ListConfig[] memory tokens,
        OracleManager router,
        string memory marketName,
        MarketManagerIsolated market,
        ICentralRegistry icr
    ) internal returns (address[] memory cTokens) {
        cTokens = new address[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            ListConfig memory listConfig = tokens[i];

            if (listConfig.canBorrow) {
                cTokens[i] = _deployBorrowableCToken(
                    listConfig,
                    marketName,
                    market,
                    icr
                );
            } else {
                cTokens[i] = _deploySimpleCToken(
                    listConfig,
                    marketName,
                    market,
                    icr
                );
            }

            listConfig.tokenConfig.cToken = cTokens[i];
            router.addCTokenSupport(cTokens[i]);
        }
    }

    function _deploySimpleCToken(
        ListConfig memory config,
        string memory marketName,
        MarketManagerIsolated market,
        ICentralRegistry icr
    ) internal returns (address) {
        IERC20 asset = IERC20(config.asset);

        address cToken = address(
            new SimpleCToken(icr, asset, address(market))
        );
        emit ContractDeployed(
            cToken,
            string.concat(marketName, ".tokens.", asset.symbol())
        );

        asset.approve(cToken, 1 * 10 ** asset.decimals());

        return cToken;
    }

    function _deployBorrowableCToken(
        ListConfig memory config,
        string memory marketName,
        MarketManagerIsolated market,
        ICentralRegistry icr
    ) internal returns (address) {
        IERC20 asset = IERC20(config.asset);

        DynamicInterestRateModel interestRateModel = new DynamicInterestRateModel(
                icr,
                config.interestConfig.baseRatePerYear,
                config.interestConfig.vertexRatePerYear,
                config.interestConfig.vertexUtilStart,
                config.interestConfig.adjustmentRate,
                config.interestConfig.adjustmentVelocity,
                config.interestConfig.vertexMultiplierMax,
                config.interestConfig.decayRate
            );
        emit ContractDeployed(
            address(interestRateModel),
            string.concat(
                marketName,
                ".",
                asset.symbol(),
                "-DynamicInterestRateModel"
            )
        );

        address cToken = address(
            new BorrowableCToken(
                icr,
                asset,
                address(market),
                address(interestRateModel)
            )
        );
        emit ContractDeployed(
            cToken,
            string.concat(marketName, ".tokens.", asset.symbol())
        );

        interestRateModel.setLinkedToken(cToken);
        asset.approve(cToken, 1 * 10 ** asset.decimals());

        return cToken;
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
