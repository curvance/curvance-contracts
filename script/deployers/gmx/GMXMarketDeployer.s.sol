// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.19;

// import "forge-std/console.sol";

// import { OracleManager } from "contracts/oracles/OracleManager.sol";
// import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
// import { GMAdaptor } from "contracts/oracles/adaptors/gmx/GMAdaptor.sol";

// import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
// import { IERC20 } from "contracts/interfaces/IERC20.sol";

// import { DeployConfiguration } from "../../utils/DeployConfiguration.sol";

// contract GMXMarketDeployer is DeployConfiguration {
//     function _deployGMXMarket(
//         string memory name,
//         address asset,
//         address alteredToken
//     ) internal {
//         address centralRegistry = _getDeployedContract("centralRegistry");
//         console.log("centralRegistry =", centralRegistry);
//         require(centralRegistry != address(0), "Set the centralRegistry!");

//         address marketManager = _getDeployedContract("marketManager");
//         console.log("marketManager =", marketManager);
//         require(marketManager != address(0), "Set the marketManager!");

//         address oracleManager = _getDeployedContract("oracleManager");
//         console.log("oracleManager =", oracleManager);
//         require(oracleManager != address(0), "Set the oracleManager!");

//         address chainlinkAdaptor = _getDeployedContract("chainlinkAdaptor");
//         if (chainlinkAdaptor == address(0)) {
//             chainlinkAdaptor = address(
//                 new ChainlinkAdaptor(ICentralRegistry(centralRegistry))
//             );
//             console.log("chainlinkAdaptor: ", chainlinkAdaptor);
//             _saveDeployedContracts("chainlinkAdaptor", chainlinkAdaptor);
//         }

//         address gmAdaptor = _getDeployedContract("gmAdaptor");
//         if (gmAdaptor == address(0)) {
//             gmAdaptor = address(
//                 new GMAdaptor(
//                     ICentralRegistry(centralRegistry),
//                     _readConfigAddress(".gmx.reader"),
//                     _readConfigAddress(".gmx.dataStore")
//                 )
//             );
//             console.log("gmAdaptor: ", gmAdaptor);
//             _saveDeployedContracts("gmAdaptor", gmAdaptor);
//         }

//         if (!OracleManager(oracleManager).isApprovedAdaptor(chainlinkAdaptor)) {
//             OracleManager(oracleManager).addApprovedAdaptor(chainlinkAdaptor);
//             console.log("oracleManager.addApprovedAdaptor: ", chainlinkAdaptor);
//         }

//         if (!OracleManager(oracleManager).isApprovedAdaptor(gmAdaptor)) {
//             OracleManager(oracleManager).addApprovedAdaptor(gmAdaptor);
//             console.log("oracleManager.addApprovedAdaptor: ", gmAdaptor);
//         }

//         if (!GMAdaptor(gmAdaptor).isSupportedAsset(asset)) {
//             GMAdaptor(gmAdaptor).addAsset(asset, alteredToken);
//         }

//         try OracleManager(oracleManager).assetPriceFeeds(asset, 0) returns (
//             address
//         ) {} catch {
//             OracleManager(oracleManager).addAssetPriceFeed(asset, gmAdaptor);
//             console.log("oracleManager.addAssetPriceFeed: ", asset);
//         }

//         // Deploy PToken
//         address pToken = _getDeployedContract(name);

//         if (pToken == address(0)) {
//             pToken = address(
//                 new GMPToken(
//                     ICentralRegistry(centralRegistry),
//                     IERC20(asset),
//                     marketManager,
//                     _readConfigAddress(".gmx.depositVault"),
//                     _readConfigAddress(".gmx.exchangeRouter"),
//                     _readConfigAddress(".gmx.router"),
//                     _readConfigAddress(".gmx.reader"),
//                     _readConfigAddress(".gmx.dataStore"),
//                     _readConfigAddress(".gmx.depositHandler")
//                 )
//             );

//             console.log("pToken: ", pToken);
//             _saveDeployedContracts(name, pToken);
//         }
//     }
// }
