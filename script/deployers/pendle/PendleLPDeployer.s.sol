// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { PendleLPCToken } from "contracts/market/token/PendleLPCToken.sol";
import { PendleLPTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendleLPTokenAdaptor.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { DeployConfiguration } from "../../utils/DeployConfiguration.sol";

contract PendleLPDeployer is DeployConfiguration {
    struct PendleLPUnderlyingParam {
        address asset;
        address chainlinkEth;
        address chainlinkUsd;
    }
    struct PendleLPParam {
        address asset;
        address pt;
        address ptOracle;
        address router;
        uint32 twapDuration;
        address underlyingAsset;
        uint8 underlyingDecimals;
        PendleLPUnderlyingParam[] underlyings;
    }

    function _deployPendleLP(
        string memory name,
        PendleLPParam memory param
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
            PendleLPUnderlyingParam memory underlyingParam = param.underlyings[
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

        // Deploy Pendle LP Adapter
        {
            address pendleLpAdapter = _getDeployedContract("pendleLpAdapter");
            if (pendleLpAdapter == address(0)) {
                pendleLpAdapter = address(
                    new PendleLPTokenAdaptor(
                        ICentralRegistry(address(centralRegistry)),
                        IPendlePTOracle(param.ptOracle)
                    )
                );
                console.log("pendleLpAdapter: ", pendleLpAdapter);
                _saveDeployedContracts("pendleLpAdapter", pendleLpAdapter);
            }

            if (
                !PendleLPTokenAdaptor(pendleLpAdapter).isSupportedAsset(
                    param.asset
                )
            ) {
                PendleLPTokenAdaptor.AdaptorData memory adapterData;
                adapterData.twapDuration = param.twapDuration;
                adapterData.pt = param.pt;
                adapterData.quoteAsset = param.underlyingAsset;
                adapterData.quoteAssetDecimals = param.underlyingDecimals;
                PendleLPTokenAdaptor(pendleLpAdapter).addAsset(
                    param.asset,
                    adapterData
                );
                console.log("pendleLpAdapter.addAsset");
            }

            if (
                !OracleManager(oracleManager).isApprovedAdaptor(
                    pendleLpAdapter
                )
            ) {
                OracleManager(oracleManager).addApprovedAdaptor(
                    pendleLpAdapter
                );
                console.log(
                    "oracleManager.addApprovedAdaptor: ",
                    pendleLpAdapter
                );
            }

            try
                OracleManager(oracleManager).assetPriceFeeds(param.asset, 0)
            returns (address /* feed */) {} catch {
                OracleManager(oracleManager).addAssetPriceFeed(
                    param.asset,
                    pendleLpAdapter
                );
                console.log("oracleManager.addAssetPriceFeed: ", param.asset);
            }
        }

        // Deploy PToken
        address pToken = _getDeployedContract(name);
        if (pToken == address(0)) {
            pToken = address(
                new PendleLPCToken(
                    ICentralRegistry(address(centralRegistry)),
                    IERC20(param.asset),
                    marketManager,
                    IPendleRouter(param.router),
                    1 days
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
