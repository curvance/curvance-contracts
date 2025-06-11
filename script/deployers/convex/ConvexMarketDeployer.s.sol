// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { Curve2PoolLPAdaptor } from "contracts/oracles/adaptors/curve/Curve2PoolLPAdaptor.sol";
import { Convex2PoolCToken } from "contracts/market/token/Convex2PoolCToken.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { DeployConfiguration } from "../../utils/DeployConfiguration.sol";

contract ConvexMarketDeployer is DeployConfiguration {
    struct ConvexUnderlyingParam {
        address asset;
        address chainlinkEth;
        address chainlinkUsd;
    }
    struct PriceBound {
        bool divideRate0;
        bool divideRate1;
        bool isCorrelated;
        uint256 lowerBound;
        uint256 upperBound;
    }
    struct ConvexMarketParam {
        address asset;
        address booster;
        uint256 pid;
        address pool;
        PriceBound priceBound;
        address rewarder;
        ConvexUnderlyingParam[] underlyings;
    }

    function _deployConvexMarket(
        string memory name,
        ConvexMarketParam memory param
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
        address curveAdaptor = _getDeployedContract("curveAdaptor");
        if (curveAdaptor == address(0)) {
            curveAdaptor = address(
                new Curve2PoolLPAdaptor(ICentralRegistry(centralRegistry))
            );
            console.log("curveAdaptor: ", curveAdaptor);
            _saveDeployedContracts("curveAdaptor", curveAdaptor);
            Curve2PoolLPAdaptor(curveAdaptor).setReentrancyConfig(2, 50_000);
            Curve2PoolLPAdaptor(curveAdaptor).setReentrancyConfig(3, 50_000);
            Curve2PoolLPAdaptor(curveAdaptor).setReentrancyConfig(4, 50_000);
        }

        // Setup underlying chainlink adapters
        for (uint256 i = 0; i < param.underlyings.length; i++) {
            ConvexUnderlyingParam memory underlyingParam = param.underlyings[
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

        // Deploy Curve adapter
        if (!OracleManager(oracleManager).isApprovedAdaptor(curveAdaptor)) {
            OracleManager(oracleManager).addApprovedAdaptor(curveAdaptor);
            console.log("oracleManager.addApprovedAdaptor: ", curveAdaptor);
        }
        if (!Curve2PoolLPAdaptor(curveAdaptor).isSupportedAsset(param.asset)) {
            Curve2PoolLPAdaptor.AdaptorData memory data;
            data.pool = param.pool;
            data.underlying0 = param.underlyings[0].asset;
            data.underlying1 = param.underlyings[1].asset;
            data.divideRate0 = param.priceBound.divideRate0;
            data.divideRate1 = param.priceBound.divideRate1;
            data.isCorrelated = param.priceBound.isCorrelated;
            data.upperBound = param.priceBound.upperBound;
            data.lowerBound = param.priceBound.lowerBound;

            Curve2PoolLPAdaptor(curveAdaptor).addAsset(param.asset, data);
            console.log("curveAdaptor.addAsset");
        }
        try
            OracleManager(oracleManager).assetPriceFeeds(param.asset, 0)
        returns (address /* feed */) {} catch {
            OracleManager(oracleManager).addAssetPriceFeed(
                param.asset,
                curveAdaptor
            );
            console.log("oracleManager.addAssetPriceFeed: ", param.asset);
        }

        // Deploy PToken
        address pToken = _getDeployedContract(name);
        if (pToken == address(0)) {
            if (param.underlyings.length == 2) {
                pToken = address(
                    new Convex2PoolCToken(
                        ICentralRegistry(centralRegistry),
                        IERC20(param.asset),
                        marketManager,
                        param.pid,
                        param.rewarder,
                        param.booster,
                        1 days
                    )
                );
            } else if (param.underlyings.length == 3) {
                pToken = address(
                    new Convex2PoolCToken(
                        ICentralRegistry(centralRegistry),
                        IERC20(param.asset),
                        marketManager,
                        param.pid,
                        param.rewarder,
                        param.booster,
                        1 days
                    )
                );
            } else if (param.underlyings.length == 4) {
                pToken = address(
                    new Convex2PoolCToken(
                        ICentralRegistry(centralRegistry),
                        IERC20(param.asset),
                        marketManager,
                        param.pid,
                        param.rewarder,
                        param.booster,
                        1 days
                    )
                );
            }
            console.log("pToken: ", pToken);
            _saveDeployedContracts(name, pToken);
        }

        // followings should be done separate because it requires dust amount deposits
        // marketManager.listToken;
        // marketManager.updatePositionToken
        // marketManager.setCollateralCaps
    }
}
