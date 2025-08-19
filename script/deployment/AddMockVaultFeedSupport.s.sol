// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import { MockPermissionV3Aggregator } from "contracts/mocks/MockPermissionV3Aggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract AddMockVaultFeedSupport is Script, DeploymentLogger {
    function run(
        address registry,
        address[] calldata vaultTokens,
        address assetToken,
        int256 price,
        bool useNativeUnderlying
    ) external recordEvents {
        IERC20 asset = IERC20(assetToken);
        price = int256(price * int256(10 ** asset.decimals()));
        ICentralRegistry icr = ICentralRegistry(registry);
        OracleManager oracleManager = OracleManager(icr.oracleManager());

        address fakeAgg = address(
            new MockPermissionV3Aggregator(
                icr,
                asset.decimals(),
                price
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
        adaptor.addAsset(assetToken, true, fakeAgg, 0);
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

            adaptor.addAsset(vaultToken, true, vaultAgg, 0);
            oracleManager.addAssetPriceFeed(vaultToken, address(adaptor));
        }
    }
}
