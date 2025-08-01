// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { TestnetToken } from "contracts/mocks/TestnetToken.sol";
import { MockOracleAdaptor } from "contracts/mocks/MockOracleAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract DeployTestTokens is Script {
    event ContractDeployed(address contractAddress, string contractName);

    DeploymentLogger logger;

    function run(
        string[] memory names,
        string[] memory symbols,
        uint8[] memory decimals,
        uint256[] memory initialBalances,
        uint240[] memory prices,
        address faucet,
        address registry
    ) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        ICentralRegistry cr = ICentralRegistry(registry);
        OracleManager oracleManager = OracleManager(cr.oracleManager());

        for (uint256 i = 0; i < names.length; i++) {
            // Create underlying token
            string memory symbol = symbols[i];
            TestnetToken token = new TestnetToken(
                names[i],
                symbol,
                decimals[i]
            );
            emit ContractDeployed(address(token), symbol);

            // Load faucet
            if (faucet != address(0)) {
                token.mint(initialBalances[i]);
                token.transfer(faucet, initialBalances[i]);
            }

            // Setup fake oracle feed
            uint240 price = prices[i];
            if (price != 0) {
                MockOracleAdaptor adaptor = new MockOracleAdaptor(
                    cr,
                    .1e18,
                    0,
                    30 days,
                    7 days
                );
                oracleManager.addApprovedAdaptor(address(adaptor));
                adaptor.addAsset(address(token));
                adaptor.setPrice(address(token), price, price);
                oracleManager.addAssetPriceFeed(
                    address(token),
                    address(adaptor)
                );
                emit ContractDeployed(
                    address(adaptor),
                    string.concat(symbol, "-Oracle")
                );
            }
        }

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }
}
