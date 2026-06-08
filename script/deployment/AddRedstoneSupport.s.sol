// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";
import { RedstoneClassicAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { RedstoneAdaptorMulticallChecker } from "contracts/calldata-checker/multicall-checker/RedstoneAdaptorMulticallChecker.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract AddRedstoneSupport is DeployScript {
    struct PullFeed {
        bytes payload;
        uint48 timestamp;
        string id;
    }

    struct PushFeed {
        bool inUSD;
        address feed;
        uint256 heartbeat;
        string id;
    }

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
        address adaptorAddr,
        address oracleManager,
        PushFeed memory feed,
        PriceGuard memory guardConfig
    ) external recordEvents {
        RedstoneClassicAdaptor adaptor = RedstoneClassicAdaptor(adaptorAddr);
        OracleManager manager = OracleManager(oracleManager);
        IERC20 token = IERC20(asset);

        _validatePriceGuard(guardConfig);
        adaptor.addAsset(asset, feed.inUSD, feed.feed, feed.heartbeat, feed.id);

        _setGuardedPriceConfig(
            BaseOracleAdaptor(address(adaptor)),
            asset,
            guardConfig
        );

        _addAssetPricingAdaptor(manager, BaseOracleAdaptor(address(adaptor)), asset);
    }

    function run(
        address asset,
        address adaptor,
        address oracleManager,
        PullFeed memory feed,
        PriceGuard memory guardConfig
    ) external recordEvents {
        RedstoneCoreAdaptor adaptor = RedstoneCoreAdaptor(adaptor);
        OracleManager manager = OracleManager(oracleManager);
        IERC20 token = IERC20(asset);

        _validatePriceGuard(guardConfig);

        // Add oracle support
        adaptor.addAsset(asset, true, token.decimals(), feed.id);
        adaptor.assetConfig(asset, true);

        // Push the first price on-chain
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool,uint48)",
            asset,
            true,
            feed.timestamp
        );
        bytes memory write = abi.encodePacked(encodedFunction, feed.payload);
        (bool success, ) = address(adaptor).call(write);
        require(success, "Failed to write price");

        // Finalize oracle support
        _setGuardedPriceConfig(
            BaseOracleAdaptor(address(adaptor)),
            asset,
            guardConfig
        );

        _addAssetPricingAdaptor(manager, BaseOracleAdaptor(address(adaptor)), asset);
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
        BaseOracleAdaptor adaptor,
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

    function deployRedstoneClassicAdaptor(
        ICentralRegistry icr,
        OracleManager oracleManager
    ) public useDeployer returns (RedstoneClassicAdaptor) {
        RedstoneClassicAdaptor adaptor  = new RedstoneClassicAdaptor(icr);
        oracleManager.addApprovedAdaptor(address(adaptor));
        emit ContractDeployed(address(adaptor),"adaptors.RedstoneClassicAdaptor");

        return adaptor;
    }

    function deployRedstoneCoreAdaptor(
        CentralRegistry registry,
        ICentralRegistry icr,
        OracleManager oracleManager
    ) public useDeployer returns (RedstoneCoreAdaptor) {
        address[] memory redstoneSigners = new address[](4);
        redstoneSigners[0] = 0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774;
        redstoneSigners[1] = 0xdEB22f54738d54976C4c0fe5ce6d408E40d88499;
        redstoneSigners[2] = 0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202;
        redstoneSigners[3] = 0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE;

        RedstoneCoreAdaptor adaptor = new RedstoneCoreAdaptor(icr, redstoneSigners, 3, "ETH", 1 minutes);
        emit ContractDeployed(
            address(adaptor),
            "adaptors.RedstoneCoreAdaptor"
        );

        address multicallChecker = address(
            new RedstoneAdaptorMulticallChecker(icr)
        );
        emit ContractDeployed(
            multicallChecker,
            "calldataCheckers.RedstoneAdaptorMulticallChecker"
        );

        registry.setMulticallChecker(
            address(adaptor),
            multicallChecker
        );
        oracleManager.addApprovedAdaptor(address(adaptor));

        return adaptor;
    }
}
