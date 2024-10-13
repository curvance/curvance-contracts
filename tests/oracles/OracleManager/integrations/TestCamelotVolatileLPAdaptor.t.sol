// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

// import { CamelotVolatileLPAdaptor } from "contracts/oracles/adaptors/camelot/CamelotVolatileLPAdaptor.sol";
// import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
// import { OracleManager } from "contracts/oracles/OracleManager.sol";
// import { BaseVolatileLPAdaptor } from "contracts/oracles/adaptors/stableswapBase/BaseVolatileLPAdaptor.sol";
// import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
// import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";

// contract TestCamelotVolatileLPAdaptor is TestBaseOracleManager {
//     address internal _BRIDGED_USDC_ADDRESS =
//         0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
//     address internal _CAMELOT_WETH_USDC =
//         0x84652bb2539513BAf36e225c930Fdd8eaa63CE27;

//     CamelotVolatileLPAdaptor public adaptor;

//     function setUp() public override {
//         _fork("ETH_NODE_URI_ARBITRUM", 148061500);

//         _deployCentralRegistry();
//         _deployOracleManager();

//         chainlinkAdaptor = new ChainlinkAdaptor(
//             ICentralRegistry(address(centralRegistry))
//         );

//         adaptor = new CamelotVolatileLPAdaptor(
//             ICentralRegistry(address(centralRegistry))
//         );
//         adaptor.addAsset(_CAMELOT_WETH_USDC);

//         chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
//         chainlinkAdaptor.addAsset(_WETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
//         chainlinkAdaptor.addAsset(
//             _BRIDGED_USDC_ADDRESS,
//             _CHAINLINK_USDC_USD,
//             0,
//             true
//         );

//         oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
//         oracleManager.addAssetPriceFeed(
//             _ETH_ADDRESS,
//             address(chainlinkAdaptor)
//         );
//         oracleManager.addAssetPriceFeed(
//             _WETH_ADDRESS,
//             address(chainlinkAdaptor)
//         );
//         oracleManager.addAssetPriceFeed(
//             _BRIDGED_USDC_ADDRESS,
//             address(chainlinkAdaptor)
//         );

//         oracleManager.addApprovedAdaptor(address(adaptor));
//         oracleManager.addAssetPriceFeed(_CAMELOT_WETH_USDC, address(adaptor));
//     }

//     function testRevertWhenUnderlyingChainAssetPriceNotSet() public {
//         chainlinkAdaptor.removeAsset(_WETH_ADDRESS);

//         vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
//         oracleManager.getPrice(_CAMELOT_WETH_USDC, true, false);
//     }

//     function testReturnsCorrectPrice() public {
//         (uint256 price, uint256 errorCode) = oracleManager.getPrice(
//             _CAMELOT_WETH_USDC,
//             true,
//             false
//         );
//         assertEq(errorCode, 0);
//         assertGt(price, 0);
//     }

//     function testRevertAfterAssetRemove() public {
//         testReturnsCorrectPrice();

//         adaptor.removeAsset(_CAMELOT_WETH_USDC);
//         vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
//         oracleManager.getPrice(_CAMELOT_WETH_USDC, true, false);
//     }

//     function testRevertAddAsset__AssetIsNotVolatileLP() public {
//         vm.expectRevert(
//             CamelotVolatileLPAdaptor
//                 .CamelotVolatileLPAdaptor__AssetIsNotVolatileLP
//                 .selector
//         );
//         adaptor.addAsset(0x01efEd58B534d7a7464359A6F8d14D986125816B);
//     }

//     function testCanUpdateAsset() public {
//         adaptor.addAsset(_CAMELOT_WETH_USDC);
//         adaptor.addAsset(_CAMELOT_WETH_USDC);
//     }

//     function testRevertGetPrice__AssetIsNotSupported() public {
//         vm.expectRevert(
//             BaseVolatileLPAdaptor
//                 .BaseVolatileLPAdaptor__AssetIsNotSupported
//                 .selector
//         );
//         adaptor.getPrice(address(0), true, false);
//     }

//     function testRevertRemoveAsset__AssetIsNotSupported() public {
//         vm.expectRevert(
//             BaseVolatileLPAdaptor
//                 .BaseVolatileLPAdaptor__AssetIsNotSupported
//                 .selector
//         );
//         adaptor.removeAsset(address(0));
//     }
// }
