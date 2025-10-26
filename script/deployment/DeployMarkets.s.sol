// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";
import { AddPlugins } from "./AddPlugins.s.sol";

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract DeployMarkets is DeployScript {
    struct DynamicInterestRateConfig {
        uint256 baseRatePerYear;
        uint256 vertexRatePerYear;
        uint256 vertexUtilStart;
        uint256 adjustmentRate;
        uint256 adjustmentVelocity;
        uint256 vertexMultiplierMax;
        uint256 decayRate;
    }

    AddPlugins internal plugin_deployer;

    constructor() {
        plugin_deployer = new AddPlugins();
    }

    struct ListConfig {
        address asset;
        bool canBorrow;
        MarketManagerIsolated.TokenConfig tokenConfig;
        DynamicInterestRateConfig interestConfig;
    }

    function run(
        address centralRegistry,
        string[] memory names,
        ListConfig[][] memory tokens,
        bool[] memory isCorrelatedMarkets,
        address wrappedNative,
        AddPlugins.AvailablePlugins[] memory plugins
    ) external recordEvents {
        CentralRegistry registry = CentralRegistry(centralRegistry);
        ICentralRegistry icr = ICentralRegistry(centralRegistry);
        OracleManager router = OracleManager(registry.oracleManager());

        for (uint256 i = 0; i < names.length; i++) {
            string memory name = string.concat("markets.", names[i]);
            ListConfig[] memory tokens = tokens[i];

            MarketManagerIsolated market = new MarketManagerIsolated(icr, 10e18, isCorrelatedMarkets[i]);
            registry.addMarketManager(address(market));
            emit ContractDeployed(
                address(market),
                string.concat(name, ".address")
            );

            plugin_deployer.deployPlugins(icr, market, wrappedNative, name, plugins[i]);

            address[] memory cTokens = deployCTokens(
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
    }

    function deployCTokens(
        ListConfig[] memory tokens,
        OracleManager router,
        string memory marketName,
        MarketManagerIsolated market,
        ICentralRegistry icr
    ) public useDeployer returns (address[] memory cTokens) {
        cTokens = new address[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            ListConfig memory listConfig = tokens[i];

            if (listConfig.canBorrow) {
                cTokens[i] = deployBorrowableCToken(
                    listConfig,
                    marketName,
                    market,
                    icr
                );
            } else {
                cTokens[i] = deploySimpleCToken(
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

    function deploySimpleCToken(
        ListConfig memory config,
        string memory marketName,
        MarketManagerIsolated market,
        ICentralRegistry icr
    ) public useDeployer returns (address) {
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

    function deployBorrowableCToken(
        ListConfig memory config,
        string memory marketName,
        MarketManagerIsolated market,
        ICentralRegistry icr
    ) public useDeployer returns (address) {
        IERC20 asset = IERC20(config.asset);

        DynamicIRM IRM = new DynamicIRM(
                icr,
                config.interestConfig.baseRatePerYear,
                config.interestConfig.vertexRatePerYear,
                config.interestConfig.vertexUtilStart,
                config.interestConfig.adjustmentVelocity,
                config.interestConfig.decayRate,
                config.interestConfig.vertexMultiplierMax
            );
        emit ContractDeployed(
            address(IRM),
            string.concat(
                marketName,
                ".",
                asset.symbol(),
                "-DynamicIRM"
            )
        );

        address cToken = address(
            new BorrowableCToken(
                icr,
                asset,
                address(market),
                address(IRM)
            )
        );
        emit ContractDeployed(
            cToken,
            string.concat(marketName, ".tokens.", asset.symbol())
        );

        IRM.setLinkedToken(cToken);
        asset.approve(cToken, 1 * 10 ** asset.decimals());

        return cToken;
    }
}
