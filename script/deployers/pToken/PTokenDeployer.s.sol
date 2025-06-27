// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { DeployConfiguration } from "../../utils/DeployConfiguration.sol";

contract PTokenDeployer is DeployConfiguration {
    struct PTokenParam {
        address asset;
        address chainlinkEth;
        address chainlinkUsd;
    }

    function _deployPToken(
        string memory name,
        PTokenParam memory param
    ) internal {
        address centralRegistry = _getDeployedContract("centralRegistry");
        console.log("centralRegistry =", centralRegistry);
        require(centralRegistry != address(0), "Set the centralRegistry!");
        address marketManager = _getDeployedContract("marketManager");
        console.log("marketManager =", marketManager);
        require(marketManager != address(0), "Set the marketManager!");
        address oracleManager = _getDeployedContract("oracleManager");
        console.log("oracleManager =", oracleManager);
        require(oracleManager != address(0), "Set the oracleManager!");

        address chainlinkAdaptor = _getDeployedContract("chainlinkAdaptor");
        if (chainlinkAdaptor == address(0)) {
            chainlinkAdaptor = address(
                new ChainlinkAdaptor(ICentralRegistry(centralRegistry))
            );
            console.log("chainlinkAdaptor: ", chainlinkAdaptor);
            _saveDeployedContracts("chainlinkAdaptor", chainlinkAdaptor);
        }

        // Setup underlying chainlink adapters.
        if (
            !ChainlinkAdaptor(chainlinkAdaptor).isSupportedAsset(param.asset)
        ) {
            // TO-DO: Have a lookup table here for param assets for whether
            // there are special heartbeats smaller than 24 hours.
            if (param.chainlinkEth != address(0)) {
                ChainlinkAdaptor(chainlinkAdaptor).addAsset(
                    param.asset,
                    param.chainlinkEth,
                    0,
                    false
                );
            }
            // TO-DO: Have a lookup table here for param assets for whether
            // there are special heartbeats smaller than 24 hours.
            if (param.chainlinkUsd != address(0)) {
                ChainlinkAdaptor(chainlinkAdaptor).addAsset(
                    param.asset,
                    param.chainlinkUsd,
                    0,
                    true
                );
            }
            console.log("chainlinkAdaptor.addAsset");
        }

        if (
            !OracleManager(oracleManager).isApprovedAdaptor(chainlinkAdaptor)
        ) {
            OracleManager(oracleManager).addApprovedAdaptor(chainlinkAdaptor);
            console.log(
                "oracleManager.addApprovedAdaptor: ",
                chainlinkAdaptor
            );
        }

        try
            OracleManager(oracleManager).assetPriceFeeds(param.asset, 0)
        returns (address /* feed */) {} catch {
            OracleManager(oracleManager).addAssetPriceFeed(
                param.asset,
                chainlinkAdaptor
            );
            console.log("oracleManager.addAssetPriceFeed: ", param.asset);
        }

        // Deploy PToken
        address pToken = _getDeployedContract(name);
        if (pToken == address(0)) {
            pToken = address(
                new SimpleCToken(
                    ICentralRegistry(address(centralRegistry)),
                    IERC20(param.asset),
                    marketManager
                )
            );

            console.log("pToken: ", pToken);
            _saveDeployedContracts(name, pToken);

            if (!OracleManager(oracleManager).isSupportedAsset(pToken)) {
                OracleManager(oracleManager).addCTokenSupport(pToken);
            }
        }

        // followings should be done separate because it requires dust amount deposits
        // marketManager.listToken;
        // marketManager.updatePositionToken
        // marketManager.setCollateralCaps
    }
}
