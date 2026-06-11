// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { RedstoneClassicAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
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
        _validatePriceGuard(guardConfig);

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

        _setGuardedPriceConfig(
            BaseOracleAdaptor(adaptor),
            vaultToken,
            guardConfig
        );

        _addAssetPricingAdaptor(
            OracleManager(icr.oracleManager()),
            BaseOracleAdaptor(adaptor),
            vaultToken
        );
    }

    function _setGuardedPriceConfig(
        BaseOracleAdaptor adaptor,
        address asset,
        PriceGuard calldata guardConfig
    ) internal {
        if (!guardConfig.enabled) {
            return;
        }

        try adaptor.setGuardedPriceConfig(
            asset,
            guardConfig.inUSD,
            _guardTimestamp(guardConfig),
            guardConfig.ips,
            guardConfig.basePrice,
            guardConfig.minPrice
        ) {} catch (bytes memory revertData) {
            adaptor.removeAsset(asset);
            _revertWithData(revertData);
        }
    }

    function _addAssetPricingAdaptor(
        OracleManager oracleManager,
        BaseOracleAdaptor adaptor,
        address asset
    ) internal {
        try oracleManager.addAssetPricingAdaptor(
            asset,
            address(adaptor),
            250,
            220,
            250,
            220
        ) {} catch (bytes memory revertData) {
            adaptor.removeAsset(asset);
            _revertWithData(revertData);
        }
    }

    function _validatePriceGuard(PriceGuard calldata guardConfig) internal view {
        if (!guardConfig.enabled) {
            return;
        }

        require(guardConfig.basePrice != 0, "invalid guard config");
        require(guardConfig.basePrice <= type(uint88).max, "invalid guard config");
        require(guardConfig.minPrice <= guardConfig.basePrice, "invalid guard config");
        require(guardConfig.ips <= type(uint40).max, "invalid guard config");

        if (guardConfig.ips == 0) {
            require(guardConfig.timestampSubtract == 0, "invalid guard config");
        } else {
            require(guardConfig.timestampSubtract >= 7 days, "invalid guard config");
            require(guardConfig.timestampSubtract < block.timestamp, "invalid guard config");
        }
    }

    function _guardTimestamp(
        PriceGuard calldata guardConfig
    ) internal view returns (uint256) {
        return guardConfig.ips > 0 ?
            block.timestamp - guardConfig.timestampSubtract :
            0;
    }

    function _revertWithData(bytes memory revertData) internal pure {
        if (revertData.length == 0) {
            revert("guard config failed");
        }

        assembly {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }
}
