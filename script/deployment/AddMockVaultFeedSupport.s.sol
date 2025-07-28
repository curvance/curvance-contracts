// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import { MockPermissionV3Aggregator } from "contracts/mocks/MockPermissionV3Aggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract AddMockVaultFeedSupport is Script {
    event ContractDeployed(address contractAddress, string contractName);

    DeploymentLogger logger;

    function run(
        address registry,
        address[] calldata vaultTokens,
        address assetToken,
        int256 price,
        bool useNativeUnderlying
    ) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        IERC20 asset = IERC20(assetToken);
        price = int256(price * int256(10 ** asset.decimals()));
        ICentralRegistry icr = ICentralRegistry(registry);
        OracleManager oracleManager = OracleManager(icr.oracleManager());

        address fakeAgg = address(
            new MockPermissionV3Aggregator(
                icr,
                asset.decimals(),
                price,
                type(int192).max,
                int192(0)
            )
        );
        emit ContractDeployed(
            fakeAgg,
            string.concat(asset.symbol(), "-", "MockPermissionV3Aggregator")
        );

        ChainlinkAdaptor adaptor = new ChainlinkAdaptor(icr);
        emit ContractDeployed(
            address(adaptor),
            string.concat(asset.symbol(), "-", "ChainlinkAdaptor")
        );
        oracleManager.addApprovedAdaptor(address(adaptor));
        adaptor.addAsset(assetToken, fakeAgg, 0, true);
        oracleManager.addAssetPriceFeed(assetToken, address(adaptor));

        for (uint256 i = 0; i < vaultTokens.length; i++) {
            address vaultToken = vaultTokens[i];
            IERC20 vault = IERC20(vaultToken);

            // Create VaultAggregator
            address vaultAssetToken = useNativeUnderlying
                ? 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
                : assetToken;
            address vaultAgg = address(
                new VaultAggregator(vaultToken, vaultAssetToken, fakeAgg)
            );
            emit ContractDeployed(
                vaultAgg,
                string.concat(
                    "VaultAggregator-",
                    asset.symbol(),
                    "-",
                    vault.symbol()
                )
            );

            adaptor.addAsset(vaultToken, vaultAgg, 0, true);
            oracleManager.addAssetPriceFeed(vaultToken, address(adaptor));
        }

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }
}
