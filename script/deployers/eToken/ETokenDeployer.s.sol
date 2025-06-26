// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { DeployConfiguration } from "../../utils/DeployConfiguration.sol";

contract ETokenDeployer is DeployConfiguration {
    struct ETokenInterestRateParam {
        uint256 adjustmentRate;
        uint256 adjustmentVelocity;
        uint256 baseRatePerYear;
        uint256 decayRate;
        uint256 vertexMultiplierMax;
        uint256 vertexRatePerYear;
        uint256 vertexUtilizationStart;
    }
    struct ETokenParam {
        address asset;
        address chainlinkEth;
        address chainlinkUsd;
        ETokenInterestRateParam interestRateParam;
    }

    function _deployEToken(
        string memory name,
        ETokenParam memory param
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

        // Setup chainlink adapters
        if (
            !ChainlinkAdaptor(chainlinkAdaptor).isSupportedAsset(param.asset)
        ) {
            if (param.chainlinkEth != address(0)) {
                ChainlinkAdaptor(chainlinkAdaptor).addAsset(
                    param.asset,
                    param.chainlinkEth,
                    0,
                    false
                );
            }
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

        // Deploy EToken
        address eToken = _getDeployedContract(name);
        if (eToken == address(0)) {
            address interestRateModel = address(
                new DynamicInterestRateModel(
                    ICentralRegistry(centralRegistry),
                    param.interestRateParam.baseRatePerYear,
                    param.interestRateParam.vertexRatePerYear,
                    param.interestRateParam.vertexUtilizationStart,
                    param.interestRateParam.adjustmentRate,
                    param.interestRateParam.adjustmentVelocity,
                    param.interestRateParam.vertexMultiplierMax,
                    param.interestRateParam.decayRate
                )
            );
            console.log("interestRateModel: ", interestRateModel);

            eToken = address(
                new BorrowableCToken(
                    ICentralRegistry(address(centralRegistry)),
                    IERC20(param.asset),
                    marketManager,
                    interestRateModel
                )
            );

            console.log("eToken: ", eToken);
            _saveDeployedContracts(name, eToken);

            if (!OracleManager(oracleManager).isSupportedAsset(eToken)) {
                OracleManager(oracleManager).addCTokenSupport(eToken);
            }
        }

        // followings should be done separate because it requires dust amount deposits
        // marketManager.listToken;
    }
}
