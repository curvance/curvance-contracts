// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
import { PendlePrincipalTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendlePrincipalTokenAdaptor.sol";

import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { DeployConfiguration } from "../../utils/DeployConfiguration.sol";

contract PendlePTDeployer is DeployConfiguration {
    struct PendlePtUnderlyingParam {
        address asset;
        address chainlinkEth;
        address chainlinkUsd;
    }
    struct PendlePTParam {
        address asset;
        address market;
        address ptOracle;
        uint32 twapDuration;
        address underlyingAsset;
        uint8 underlyingDecimals;
        PendlePtUnderlyingParam[] underlyings;
    }

    function _deployPendlePT(
        string memory name,
        PendlePTParam memory param
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

        // Setup underlying chainlink adapters
        for (uint256 i = 0; i < param.underlyings.length; i++) {
            PendlePtUnderlyingParam memory underlyingParam = param.underlyings[
                i
            ];

            if (
                !ChainlinkAdaptor(chainlinkAdaptor).isSupportedAsset(
                    underlyingParam.asset
                )
            ) {
                if (underlyingParam.chainlinkEth != address(0)) {
                    ChainlinkAdaptor(chainlinkAdaptor).addAsset(
                        underlyingParam.asset,
                        underlyingParam.chainlinkEth,
                        0,
                        false
                    );
                }
                if (underlyingParam.chainlinkUsd != address(0)) {
                    ChainlinkAdaptor(chainlinkAdaptor).addAsset(
                        underlyingParam.asset,
                        underlyingParam.chainlinkUsd,
                        0,
                        true
                    );
                }
                console.log("chainlinkAdaptor.addAsset");
            }

            if (
                !OracleManager(oracleManager).isApprovedAdaptor(
                    chainlinkAdaptor
                )
            ) {
                OracleManager(oracleManager).addApprovedAdaptor(
                    chainlinkAdaptor
                );
                console.log(
                    "oracleManager.addApprovedAdaptor: ",
                    chainlinkAdaptor
                );
            }

            try
                OracleManager(oracleManager).assetPriceFeeds(
                    underlyingParam.asset,
                    0
                )
            returns (address /* feed */) {} catch {
                OracleManager(oracleManager).addAssetPriceFeed(
                    underlyingParam.asset,
                    chainlinkAdaptor
                );
                console.log(
                    "oracleManager.addAssetPriceFeed: ",
                    underlyingParam.asset
                );
            }
        }

        // Deploy Pendle PT Adapter
        {
            address pendlePtAdapter = _getDeployedContract("pendlePtAdapter");
            if (pendlePtAdapter == address(0)) {
                pendlePtAdapter = address(
                    new PendlePrincipalTokenAdaptor(
                        ICentralRegistry(address(centralRegistry)),
                        IPendlePTOracle(param.ptOracle)
                    )
                );
                console.log("pendlePtAdapter: ", pendlePtAdapter);
                _saveDeployedContracts("pendlePtAdapter", pendlePtAdapter);
            }

            if (
                !PendlePrincipalTokenAdaptor(pendlePtAdapter).isSupportedAsset(
                    param.asset
                )
            ) {
                PendlePrincipalTokenAdaptor.AdaptorData memory adapterData;
                adapterData.market = IPMarket(param.market);
                adapterData.twapDuration = param.twapDuration;
                adapterData.quoteAsset = param.underlyingAsset;
                adapterData.quoteAssetDecimals = param.underlyingDecimals;
                PendlePrincipalTokenAdaptor(pendlePtAdapter).addAsset(
                    param.asset,
                    adapterData
                );
                console.log("pendlePtAdapter.addAsset");
            }

            if (
                !OracleManager(oracleManager).isApprovedAdaptor(
                    pendlePtAdapter
                )
            ) {
                OracleManager(oracleManager).addApprovedAdaptor(
                    pendlePtAdapter
                );
                console.log(
                    "oracleManager.addApprovedAdaptor: ",
                    pendlePtAdapter
                );
            }

            try
                OracleManager(oracleManager).assetPriceFeeds(param.asset, 0)
            returns (address /* feed */) {} catch {
                OracleManager(oracleManager).addAssetPriceFeed(
                    param.asset,
                    pendlePtAdapter
                );
                console.log("oracleManager.addAssetPriceFeed: ", param.asset);
            }
        }

        // Deploy PToken
        address pToken = _getDeployedContract(name);
        if (pToken == address(0)) {
            pToken = address(
                new SimplePToken(
                    ICentralRegistry(address(centralRegistry)),
                    IERC20(param.asset),
                    marketManager
                )
            );

            console.log("pToken: ", pToken);
            _saveDeployedContracts(name, pToken);

            if (!OracleManager(oracleManager).isSupportedAsset(pToken)) {
                OracleManager(oracleManager).addMTokenSupport(pToken);
            }
        }

        // followings should be done separate because it requires dust amount deposits
        // marketManager.listToken;
        // marketManager.updatePositionToken
        // marketManager.setCollateralCaps
    }
}
