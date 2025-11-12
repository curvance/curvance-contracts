// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";
import { RedstoneClassicAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";
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

    function run(
        address asset,
        address adaptorAddr,
        address oracleManager,
        PushFeed memory feed
    ) external recordEvents {
        RedstoneClassicAdaptor adaptor = RedstoneClassicAdaptor(adaptorAddr);
        OracleManager manager = OracleManager(oracleManager);
        IERC20 token = IERC20(asset);

        adaptor.addAsset(asset, feed.inUSD, feed.feed, feed.heartbeat, feed.id);
        manager.addAssetPricingAdaptor(asset, address(adaptor), true, 100, 50);
    }

    function run(
        address asset,
        address adaptor,
        address oracleManager,
        PullFeed memory feed
    ) external recordEvents {
        RedstoneCoreAdaptor adaptor = RedstoneCoreAdaptor(adaptor);
        OracleManager manager = OracleManager(oracleManager);
        IERC20 token = IERC20(asset);

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
        manager.addAssetPricingAdaptor(asset, address(adaptor), true, 100, 50);
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
