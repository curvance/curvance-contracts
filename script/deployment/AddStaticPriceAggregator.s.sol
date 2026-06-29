// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";
import { StaticPriceAggregator } from "contracts/oracles/adaptors/wrappedAggregators/StaticPriceAggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract AddStaticPriceAggregator is DeployScript {
    struct PriceGuard {
        bool enabled;
        bool inUSD;
        uint256 timestampSubtract;
        uint256 ips;
        uint256 basePrice;
        uint256 minPrice;
    }

    function run(
        address asset,
        uint256 staticPrice,
        address adaptorAddress,
        address oracleManager,
        uint256 heartbeat,
        bool inUSD,
        PriceGuard memory guardConfig
    ) external recordEvents {
        IERC20 token = IERC20(asset);
        _validatePriceGuard(guardConfig);

        address agg = address(new StaticPriceAggregator(staticPrice));
        emit ContractDeployed(agg, string.concat("StaticPriceAggregator-", token.symbol()));

        // Register on chainlink adaptor and OracleManager
        ChainlinkAdaptor adaptor = ChainlinkAdaptor(adaptorAddress);
        adaptor.addAsset(asset, inUSD, agg, heartbeat);

        _setGuardedPriceConfig(
            BaseOracleAdaptor(address(adaptor)),
            asset,
            guardConfig
        );

        OracleManager manager = OracleManager(oracleManager);
        _addAssetPricingAdaptor(manager, adaptor, asset);
    }

    function _setGuardedPriceConfig(
        BaseOracleAdaptor adaptor,
        address asset,
        PriceGuard memory guardConfig
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
        OracleManager manager,
        ChainlinkAdaptor adaptor,
        address asset
    ) internal {
        try manager.addAssetPricingAdaptor(
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

    function _validatePriceGuard(PriceGuard memory guardConfig) internal view {
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
        PriceGuard memory guardConfig
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
