// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

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
        uint240[] memory price,
        address faucet,
        address registry
    ) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        ICentralRegistry cr = ICentralRegistry(registry);

        // Debug: Check if the registry address is valid
        require(registry != address(0), "Registry address is zero");
        require(registry.code.length > 0, "Registry has no code deployed");

        // Debug: Try to call oracleManager with explicit error handling
        address oracleManagerAddress;
        try cr.oracleManager() returns (address manager) {
            oracleManagerAddress = manager;
        } catch {
            revert("Failed to call oracleManager() on registry");
        }

        require(
            oracleManagerAddress != address(0),
            "Oracle Manager not set in Central Registry"
        );
        OracleManager oracleManager = OracleManager(oracleManagerAddress);
        for (uint256 i = 0; i < names.length; i++) {
            // Create underlying token
            TestnetToken token = new TestnetToken(
                names[i],
                symbols[i],
                decimals[i]
            );
            emit ContractDeployed(address(token), symbols[i]);

            // Load faucet
            if (faucet != address(0)) {
                token.mint(initialBalances[i]);
                token.transfer(faucet, initialBalances[i]);
            }

            // Setup fake oracle feed
            if (price[i] != 0) {
                MockOracleAdaptor adaptor = new MockOracleAdaptor(cr);
                oracleManager.addApprovedAdaptor(address(adaptor));
                adaptor.addAsset(address(token));
                adaptor.setPrice(address(token), price[i], price[i]);
                oracleManager.addAssetPriceFeed(
                    address(token),
                    address(adaptor)
                );
                emit ContractDeployed(
                    address(adaptor),
                    string.concat(symbols[i], "-Oracle")
                );
            }
        }

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }
}
