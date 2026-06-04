// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { RedstoneClassicAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract AddRedstoneVaultAggSupport is DeployScript {
    struct PriceGuard {
        bool enabled;
        bool inUSD;
        uint256 timestampSubtract;
        uint256 ips;
        uint256 basePrice;
        uint256 minPrice;
    }

    function run(
        address registry,
        address adaptor,
        address vaultToken,
        address assetToken,
        address feed,
        string memory feedId,
        bool inUSD,
        uint256 heartbeat,
        PriceGuard calldata guardConfig
    ) external recordEvents {
        ICentralRegistry icr = ICentralRegistry(registry);

        address vaultAgg = address(
            new VaultAggregator(vaultToken, assetToken, feed, feedId)
        );

        emit ContractDeployed(
            vaultAgg,
            string.concat(
                "VaultAggregator-",
                IERC20(assetToken).symbol(),
                "-",
                IERC20(vaultToken).symbol()
            )
        );

        RedstoneClassicAdaptor(adaptor).addAsset(
            vaultToken,
            inUSD,
            vaultAgg,
            heartbeat,
            feedId
        );

        if (guardConfig.enabled) {
            RedstoneClassicAdaptor(adaptor).setGuardedPriceConfig(
                vaultToken,
                guardConfig.inUSD,
                guardConfig.ips > 0 ? block.timestamp - guardConfig.timestampSubtract : 0,
                guardConfig.ips,
                guardConfig.basePrice,
                guardConfig.minPrice
            );
        }

        OracleManager(icr.oracleManager()).addAssetPricingAdaptor(
            vaultToken,
            adaptor,
            250,
            220,
            250,
            220
        );
    }
}
