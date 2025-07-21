// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";

contract DeployMarkets is Script {
    struct ListConfig {
        address underlyingAddress;
        bool canBorrow;
        MarketManagerIsolated.TokenConfig marketConfig;
    }

    event ContractDeployed(address contractAddress, string contractName);

    DeploymentLogger logger;

    function run(
        address centralRegistry,
        string[] memory names,
        ListConfig[][2] memory tokens,
        uint256[] memory interestFactors,
        address wrappedNative,
        address wrappedEth,
        address interestRateModel,
    ) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        CentralRegistry registry = CentralRegistry(centralRegistry);
        ICentralRegistry icr = ICentralRegistry(centralRegistry);

        if(interestRateModel == address(0)) {
            DynamicInterestRateModel interestRateModel = new DynamicInterestRateModel(
                cr,
                1000,
                1000,
                5000,
                43200,
                5000,
                100000000,
                100
            );
        } else {
            DynamicInterestRateModel interestRateModel = DynamicInterestRateModel(interestRateModel);
        }

        //NOTE: Make 3 markets per market? So we can make low,mid,high risk profiles
        for (uint256 i = 0; i < marketName.length; i++) {
            string memory name = marketName[i];
            address[] memory tokens = listTokens[i];
            uint256 interestFactor = interestFactors[i];

            MarketManagerIsolated market = new MarketManagerIsolated(icr);
            registry.addMarketManager(address(market), interestFactor);
            emit ContractDeployed(
                address(market),
                string.concat("Market-", name)
            );
            _deployPlugins(icr, market, wrappedNative, wrappedEth, name);

            address[2] memory cTokens;
            for (uint256 j = 0; j < tokens.length; j++) {
                ListConfig memory listConfig = tokens[j];

                if (listConfig.canBorrow) {
                    cTokens[j] = _deployBorrowableCToken();
                } else {
                    cTokens[j] = _deploySimpleCToken();
                }

                // TODO: router.addCTokenSupport(cToken);
                market.updateTokenConfig(tokenConfig)
            }
            market.listTokens(cTokens[0], cTokens[1]);
            // TODO: Need to update this so we arent setting a market config per token but by the market
            market.updateTokenConfig(tokens[0].marketConfig);
        }

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }

    function _deploySimpleCToken() internal {
        // TODO: Implement

    }

    function _deployBorrowableCToken() internal {
        // TODO: Implement
        // interestRateModel.setLinkedToken(cToken);
    }

    function _deployPlugins(
        ICentralRegistry icr,
        MarketManagerIsolated market,
        address wrappedNative,
        address wrappedEth,
        string memory marketName
    ) internal {
        // TODO: Ask a question about 'wrappedNative' is that 'wrappedEth'? I read it as like wrapped MON for example when on Monad
        simplePositionManager = new SimplePositionManager(
            icr,
            marketManager,
            wrappedNative
        );
        MarketManagerIsolated(marketManager).addPositionManager(
            address(simplePositionManager)
        );
        emit ContractDeployed(
            address(simplePositionManager),
            string.concat("Market-", name, "-simplePositionManager")
        );

        simpleZapper = new SimpleZapper(
            ICentralRegistry(centralRegistry),
            wrappedEth
        );
        emit ContractDeployed(
            address(simpleZapper),
            string.concat("Market-", name, "-simpleZapper")
        );
    }
}
