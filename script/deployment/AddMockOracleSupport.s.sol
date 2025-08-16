// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { MockOracleAdaptor } from "contracts/mocks/MockOracleAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract AddMockOracleSupport is Script {
    event ContractDeployed(address contractAddress, string contractName);

    DeploymentLogger logger;

    function run(
        address registry,
        address mockOracle,
        address[] calldata assets,
        uint240[] calldata usdPrices,
        uint240[] calldata nativePrices
    ) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        ICentralRegistry cr = ICentralRegistry(registry);
        OracleManager oracleManager = OracleManager(cr.oracleManager());
        MockOracleAdaptor adaptor = MockOracleAdaptor(mockOracle);

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint240 usdPrice = usdPrices[i];
            uint240 nativePrice = nativePrices[i];

            adaptor.addAsset(asset);
            adaptor.setPrice(asset, usdPrice, nativePrice);
            oracleManager.addAssetPriceFeed(asset, address(adaptor));
        }

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }
}
