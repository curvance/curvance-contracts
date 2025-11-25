// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract AddChainlinkVaultAggSupport is DeployScript {
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
        bool inUSD,
        PriceGuard memory guardConfig
    ) external recordEvents {
        ICentralRegistry icr = ICentralRegistry(registry);
        OracleManager oracleManager = OracleManager(icr.oracleManager());
        ChainlinkAdaptor chainlink = ChainlinkAdaptor(adaptor);

        IERC20 asset = IERC20(assetToken);
        IERC20 vault = IERC20(vaultToken);

        address vaultAgg = address(
            new VaultAggregator(address(vault), address(asset), feed, "")
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

        chainlink.addAsset(vaultToken, inUSD, vaultAgg, 0);
        oracleManager.addAssetPricingAdaptor(vaultToken, adaptor, 250, 220, 250, 220);

        if(guardConfig.enabled) {
            adaptor.setGuardedPriceConfig(
                asset,
                guardConfig.inUSD,
                guardConfig.ips > 0 ? block.timestamp - guardConfig.timestampSubtract : 0,
                guardConfig.ips,
                guardConfig.basePrice,
                guardConfig.minPrice
            );
        }
    }
}
