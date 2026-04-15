// // SPDX-License-Identifier: BUSL-1.1
// pragma solidity 0.8.28;

// import { Test, console } from "forge-std/Test.sol";
// import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
// import { ProtocolReader } from "contracts/views/ProtocolReader.sol";

// contract TestProtocolReaderMonadFork is Test {
//     address constant CENTRAL_REGISTRY = 0x1310f352f1389969Ece6741671c4B919523912fF;
//     address constant PROTOCOL_READER = 0x4Fa99687a90948A930BE2c1Cc540C12fD525bE73;
//     address constant USER = 0x029Cf33E40f779e3632CBa317bd43a836e117B5C;

//     ICentralRegistry centralRegistry;
//     ProtocolReader protocolReader;

//     function setUp() public {
//         vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_ARCHIVE"));

//         centralRegistry = ICentralRegistry(CENTRAL_REGISTRY);
//         // Deploy fresh ProtocolReader with current source (deployed version
//         // may not have getMarketStates yet).
//         protocolReader = new ProtocolReader(centralRegistry);
//     }

//     function test_getMarketStates() public view {
//         address[] memory markets = centralRegistry.marketManagers();
//         console.log("Number of market managers:", markets.length);

//         for (uint256 i; i < markets.length; ++i) {
//             console.log("Market manager [%d]: %s", i, markets[i]);
//         }

//         (
//             ProtocolReader.DynamicMarketData[] memory dynamicMarkets,
//             ProtocolReader.UserMarket[] memory userMarkets
//         ) = protocolReader.getMarketStates(markets, USER);

//         for (uint256 i; i < dynamicMarkets.length; ++i) {
//             console.log("--- Dynamic Market [%d] ---", i);
//             console.log("  address:", dynamicMarkets[i]._address);
//             console.log("  tokens count:", dynamicMarkets[i].tokens.length);

//             for (uint256 j; j < dynamicMarkets[i].tokens.length; ++j) {
//                 console.log("  Token [%d]: %s", j, dynamicMarkets[i].tokens[j]._address);
//                 console.log("    totalSupply:", dynamicMarkets[i].tokens[j].totalSupply);
//                 console.log("    exchangeRate:", dynamicMarkets[i].tokens[j].exchangeRate);
//                 console.log("    totalAssets:", dynamicMarkets[i].tokens[j].totalAssets);
//                 console.log("    collateral:", dynamicMarkets[i].tokens[j].collateral);
//                 console.log("    debt:", dynamicMarkets[i].tokens[j].debt);
//                 console.log("    sharePrice:", dynamicMarkets[i].tokens[j].sharePrice);
//                 console.log("    assetPrice:", dynamicMarkets[i].tokens[j].assetPrice);
//                 console.log("    borrowRate:", dynamicMarkets[i].tokens[j].borrowRate);
//                 console.log("    utilizationRate:", dynamicMarkets[i].tokens[j].utilizationRate);
//                 console.log("    supplyRate:", dynamicMarkets[i].tokens[j].supplyRate);
//                 console.log("    liquidity:", dynamicMarkets[i].tokens[j].liquidity);
//             }
//         }

//         for (uint256 i; i < userMarkets.length; ++i) {
//             console.log("--- User Market [%d] ---", i);
//             console.log("  address:", userMarkets[i]._address);
//             console.log("  collateral:", userMarkets[i].collateral);
//             console.log("  maxDebt:", userMarkets[i].maxDebt);
//             console.log("  debt:", userMarkets[i].debt);
//             console.log("  positionHealth:", userMarkets[i].positionHealth);
//             console.log("  errorCodeHit:", userMarkets[i].errorCodeHit);
//             console.log("  tokens count:", userMarkets[i].tokens.length);

//             for (uint256 j; j < userMarkets[i].tokens.length; ++j) {
//                 console.log("  User Token [%d]: %s", j, userMarkets[i].tokens[j]._address);
//                 console.log("    userAssetBalance:", userMarkets[i].tokens[j].userAssetBalance);
//                 console.log("    userShareBalance:", userMarkets[i].tokens[j].userShareBalance);
//                 console.log("    userUnderlyingBalance:", userMarkets[i].tokens[j].userUnderlyingBalance);
//                 console.log("    userCollateral:", userMarkets[i].tokens[j].userCollateral);
//                 console.log("    userDebt:", userMarkets[i].tokens[j].userDebt);
//                 console.log("    liquidationPrice:", userMarkets[i].tokens[j].liquidationPrice);
//             }
//         }
//     }
// }
