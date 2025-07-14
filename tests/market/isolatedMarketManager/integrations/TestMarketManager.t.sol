// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.19;

// import { TestBaseMarketManagerEntropy } from "../TestBaseMarketManagerEntropy.sol";
// import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
// import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
// import { MockSimpleCToken } from "contracts/mocks/MockSimpleCToken.sol";
// import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
// import { EToken } from "contracts/market/token/EToken.sol";
// import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

// contract TestMarketManager is TestBaseMarketManagerEntropy {
//     function setUp() public override {
//         _fork();

//         _deployCentralRegistry();
//         _deployCVE();
//         _deployRewardManager();
//         _deployVeCVE();
//         _deployGaugeManager();
//         _deployMarketManager();
//         // eth/usd is needed in oracle manager constructor
//         chainlinkEthUsd = chainlinkEthUsds[
//             block.chainid
//         ] = new MockV3Aggregator(8, 1500e8, 1e50, 1e6);
//         _deployOracleManager();
//         chainlinkAdaptor = chainlinkAdaptors[
//             block.chainid
//         ] = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
//         oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
//         // start gauge to enable deposits
//         vm.warp(veCVE.nextEpochStartTime() + 1000);
//         chainlinkEthUsd.updateAnswer(1500e8);
//     }

//     function testHypotheticalLiquidityOf() public {
//         address[] memory users = new address[](3);
//         users[0] = address(0x1111);
//         users[1] = address(0x2222);
//         users[2] = address(0x3333);

//         noOfCollateralTokens = 2;
//         noOfDebtTokens = 2;

//         MockSimpleCToken[] memory cTokens = new MockSimpleCToken[](
//             noOfCollateralTokens
//         );
//         EToken[] memory eTokens = new EToken[](noOfDebtTokens);
//         MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
//             noOfCollateralTokens
//         );
//         MockV3Aggregator[]
//             memory cTokensUnderlyingAgg = new MockV3Aggregator[](
//                 noOfCollateralTokens
//             );
//         MockV3Aggregator[] memory eTokensAgg = new MockV3Aggregator[](
//             noOfDebtTokens
//         );

//         (
//             cTokens,
//             cTokensAgg,
//             cTokensUnderlyingAgg
//         ) = _genCollateralateraltoken(noOfCollateralTokens, 0);
//         (eTokens, eTokensAgg) = _genEarnToken(noOfDebtTokens);

//         _genCollateral(users[0], cTokens[0], 100e18);
//         _postCollateral(users[0], cTokens[0], 100e18);

//         _genCollateral(users[1], cTokens[1], 100e18);
//         _postCollateral(users[1], cTokens[1], 100e18);

//         _genCollateral(users[2], cTokens[1], 100e18);
//         _postCollateral(users[2], cTokens[1], 100e18);

//         _supplyEToken(users[2], eTokens[0], 300e18);

//         _borrow(users[0], eTokens[0], 70e18);
//         _borrow(users[1], eTokens[0], 70e18);
//         _borrow(users[2], eTokens[0], 70e18);

//         for (uint256 i = 0; i < noOfCollateralTokens; i++) {
//             skip(20 minutes);
//             _updateRoundData(cTokensAgg[i], 0, 1e7);
//         }

//         vm.expectRevert(
//             MarketManagerIsolated.MarketManager__InvalidParameter.selector
//         );
//         marketManagerIsolated.hypotheticalLiquidityOf(
//             users[0],
//             address(cTokens[0]),
//             0,
//             1
//         );

//         (uint256 liquidity, uint256 debt, ) = marketManagerIsolated
//             .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);

//         assertEq(liquidity, 0);
//         assertGt(debt, 0);
//     }

//     function testPostCollateral() public {
//         address[] memory users = new address[](3);
//         users[0] = address(0x1111);
//         users[1] = address(0x2222);
//         users[2] = address(0x3333);

//         noOfCollateralTokens = 2;
//         noOfDebtTokens = 2;

//         MockSimpleCToken[] memory cTokens = new MockSimpleCToken[](
//             noOfCollateralTokens
//         );
//         EToken[] memory eTokens = new EToken[](noOfDebtTokens);
//         MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
//             noOfCollateralTokens
//         );
//         MockV3Aggregator[]
//             memory cTokensUnderlyingAgg = new MockV3Aggregator[](
//                 noOfCollateralTokens
//             );
//         MockV3Aggregator[] memory eTokensAgg = new MockV3Aggregator[](
//             noOfDebtTokens
//         );

//         (
//             cTokens,
//             cTokensAgg,
//             cTokensUnderlyingAgg
//         ) = _genCollateralateraltoken(noOfCollateralTokens, 0);
//         (eTokens, eTokensAgg) = _genEarnToken(noOfDebtTokens);

//         _genCollateral(users[0], cTokens[0], 1 ether);

//         vm.expectRevert(
//             MarketManagerIsolated.MarketManager__InvalidParameter.selector
//         );
//         vm.prank(users[0]);
//         cTokens[0].postCollateral(
//             0
//         );

//         vm.expectRevert(
//             MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
//         );
//         vm.prank(users[0]);
//         cTokens[0].postCollateral(
//             2 ether
//         );

//         vm.prank(users[0]);
//         cTokens[0].postCollateral(
//             1 ether
//         );
//     }

//     function testRemoveCollateral() public {
//         address[] memory users = new address[](3);
//         users[0] = address(0x1111);
//         users[1] = address(0x2222);
//         users[2] = address(0x3333);

//         noOfCollateralTokens = 2;
//         noOfDebtTokens = 2;

//         MockSimpleCToken[] memory cTokens = new MockSimpleCToken[](
//             noOfCollateralTokens
//         );
//         EToken[] memory eTokens = new EToken[](noOfDebtTokens);
//         MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
//             noOfCollateralTokens
//         );
//         MockV3Aggregator[]
//             memory cTokensUnderlyingAgg = new MockV3Aggregator[](
//                 noOfCollateralTokens
//             );
//         MockV3Aggregator[] memory eTokensAgg = new MockV3Aggregator[](
//             noOfDebtTokens
//         );

//         (
//             cTokens,
//             cTokensAgg,
//             cTokensUnderlyingAgg
//         ) = _genCollateralateraltoken(noOfCollateralTokens, 0);
//         (eTokens, eTokensAgg) = _genEarnToken(noOfDebtTokens);

//         _genCollateral(users[0], cTokens[0], 1 ether);
//         _postCollateral(users[0], cTokens[0], 1 ether);

//         skip(30 minutes);

//         vm.expectRevert(
//             MarketManagerIsolated.MarketManager__InvalidParameter.selector
//         );
//         cTokens[0].removeCollateral(0);

//         vm.expectRevert(MarketManagerIsolated.MarketManager__InvariantError.selector);
//         cTokens[0].removeCollateral(1 ether);

//         vm.expectRevert(
//             MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
//         );
//         vm.prank(users[0]);
//         cTokens[0].removeCollateral(2 ether);

//         vm.prank(users[0]);
//         cTokens[0].removeCollateral(1 ether);
//     }

//     function testRemoveCollateralAfterRedeemPaused() public {
//         address[] memory users = new address[](3);
//         users[0] = address(0x1111);
//         users[1] = address(0x2222);
//         users[2] = address(0x3333);

//         noOfCollateralTokens = 2;
//         noOfDebtTokens = 2;

//         MockSimpleCToken[] memory cTokens = new MockSimpleCToken[](
//             noOfCollateralTokens
//         );
//         EToken[] memory eTokens = new EToken[](noOfDebtTokens);
//         MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
//             noOfCollateralTokens
//         );
//         MockV3Aggregator[]
//             memory cTokensUnderlyingAgg = new MockV3Aggregator[](
//                 noOfCollateralTokens
//             );
//         MockV3Aggregator[] memory eTokensAgg = new MockV3Aggregator[](
//             noOfDebtTokens
//         );

//         (
//             cTokens,
//             cTokensAgg,
//             cTokensUnderlyingAgg
//         ) = _genCollateralateraltoken(noOfCollateralTokens, 0);
//         (eTokens, eTokensAgg) = _genEarnToken(noOfDebtTokens);

//         _genCollateral(users[0], cTokens[0], 1 ether);
//         _postCollateral(users[0], cTokens[0], 1 ether);

//         skip(30 minutes);

//         marketManagerIsolated.setRedeemPaused(true);

//         vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
//         vm.prank(users[0]);
//         cTokens[0].removeCollateral(1 ether);

//         marketManagerIsolated.setRedeemPaused(false);
//         vm.prank(users[0]);
//         cTokens[0].removeCollateral(1 ether);
//     }

//     function testPositionCloseAfterRemoveCollateral() public {
//         address[] memory users = new address[](3);
//         users[0] = address(0x1111);
//         users[1] = address(0x2222);
//         users[2] = address(0x3333);

//         noOfCollateralTokens = 2;
//         noOfDebtTokens = 2;

//         MockSimpleCToken[] memory cTokens = new MockSimpleCToken[](
//             noOfCollateralTokens
//         );
//         EToken[] memory eTokens = new EToken[](noOfDebtTokens);
//         MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
//             noOfCollateralTokens
//         );
//         MockV3Aggregator[]
//             memory cTokensUnderlyingAgg = new MockV3Aggregator[](
//                 noOfCollateralTokens
//             );
//         MockV3Aggregator[] memory eTokensAgg = new MockV3Aggregator[](
//             noOfDebtTokens
//         );

//         (
//             cTokens,
//             cTokensAgg,
//             cTokensUnderlyingAgg
//         ) = _genCollateralateraltoken(noOfCollateralTokens, 0);
//         (eTokens, eTokensAgg) = _genEarnToken(noOfDebtTokens);

//         _genCollateral(users[0], cTokens[0], 1 ether);
//         _postCollateral(users[0], cTokens[0], 1 ether);

//         skip(30 minutes);

//         uint256 collateralSurplus;
//         uint256 liquidityDeficit;
//         bool[] memory positionsToClose;
//         (collateralSurplus, liquidityDeficit, positionsToClose) = marketManagerIsolated
//             .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);

//         assertEq(positionsToClose.length, 1);
//         assertFalse(positionsToClose[0]);
//         (bool hasPosition, , ) = curvanceAuxiliaryData.tokenDataOf(
//             users[0],
//             address(cTokens[0])
//         );
//         assertTrue(hasPosition);

//         vm.prank(users[0]);
//         cTokens[0].removeCollateral(1 ether);

//         (hasPosition, , ) = curvanceAuxiliaryData.tokenDataOf(
//             users[0],
//             address(cTokens[0])
//         );
//         assertFalse(hasPosition);

//         (collateralSurplus, liquidityDeficit, positionsToClose) = marketManagerIsolated
//             .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);
//         assertEq(collateralSurplus, 0);
//         assertEq(liquidityDeficit, 0);
//     }

//     function testPositionCloseAfterRedeem() public {
//         address[] memory users = new address[](3);
//         users[0] = address(0x1111);
//         users[1] = address(0x2222);
//         users[2] = address(0x3333);

//         noOfCollateralTokens = 2;
//         noOfDebtTokens = 2;

//         MockSimpleCToken[] memory cTokens = new MockSimpleCToken[](
//             noOfCollateralTokens
//         );
//         EToken[] memory eTokens = new EToken[](noOfDebtTokens);
//         MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
//             noOfCollateralTokens
//         );
//         MockV3Aggregator[]
//             memory cTokensUnderlyingAgg = new MockV3Aggregator[](
//                 noOfCollateralTokens
//             );
//         MockV3Aggregator[] memory eTokensAgg = new MockV3Aggregator[](
//             noOfDebtTokens
//         );

//         (
//             cTokens,
//             cTokensAgg,
//             cTokensUnderlyingAgg
//         ) = _genCollateralateraltoken(noOfCollateralTokens, 0);
//         (eTokens, eTokensAgg) = _genEarnToken(noOfDebtTokens);

//         _genCollateral(users[0], cTokens[0], 1 ether);
//         _postCollateral(users[0], cTokens[0], 1 ether);

//         skip(30 minutes);

//         uint256 collateralSurplus;
//         uint256 liquidityDeficit;
//         bool[] memory positionsToClose;
//         (collateralSurplus, liquidityDeficit, positionsToClose) = marketManagerIsolated
//             .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);

//         assertEq(positionsToClose.length, 1);
//         assertFalse(positionsToClose[0]);
//         (bool hasPosition, , ) = curvanceAuxiliaryData.tokenDataOf(
//             users[0],
//             address(cTokens[0])
//         );
//         assertTrue(hasPosition);

//         vm.prank(users[0]);
//         cTokens[0].withdrawCollateral(1 ether, users[0], users[0]);

//         (hasPosition, , ) = curvanceAuxiliaryData.tokenDataOf(
//             users[0],
//             address(cTokens[0])
//         );
//         assertFalse(hasPosition);

//         (collateralSurplus, liquidityDeficit, positionsToClose) = marketManagerIsolated
//             .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);
//         assertEq(collateralSurplus, 0);
//         assertEq(liquidityDeficit, 0);
//     }

//     function testPositionCloseAfterLiquidate() public {
//         address[] memory users = new address[](3);
//         users[0] = address(0x1111);
//         users[1] = address(0x2222);
//         users[2] = address(0x3333);

//         noOfCollateralTokens = 2;
//         noOfDebtTokens = 2;

//         MockSimpleCToken[] memory cTokens = new MockSimpleCToken[](
//             noOfCollateralTokens
//         );
//         EToken[] memory eTokens = new EToken[](noOfDebtTokens);
//         MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
//             noOfCollateralTokens
//         );
//         MockV3Aggregator[]
//             memory cTokensUnderlyingAgg = new MockV3Aggregator[](
//                 noOfCollateralTokens
//             );
//         MockV3Aggregator[] memory eTokensAgg = new MockV3Aggregator[](
//             noOfDebtTokens
//         );

//         (
//             cTokens,
//             cTokensAgg,
//             cTokensUnderlyingAgg
//         ) = _genCollateralateraltoken(noOfCollateralTokens, 0);
//         (eTokens, eTokensAgg) = _genEarnToken(noOfDebtTokens);

//         _genCollateral(users[0], cTokens[0], 500e18);
//         _postCollateral(users[0], cTokens[0], 500e18);

//         _supplyEToken(users[2], eTokens[0], 1_500e18);
//         _borrow(users[0], eTokens[0], 300e18);

//         _supplyEToken(users[2], eTokens[1], 1_500e18);
//         _borrow(users[0], eTokens[1], 50e18);

//         skip(20 minutes);
//         _updateRoundData(cTokensAgg[0], 0, 0.9e8);

//         uint256 collateralSurplus;
//         uint256 liquidityDeficit;
//         bool[] memory positionsToClose;
//         (collateralSurplus, liquidityDeficit, positionsToClose) = marketManagerIsolated
//             .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);

//         bool hasPosition;
//         assertEq(positionsToClose.length, 3);
//         assertFalse(positionsToClose[0]);
//         assertFalse(positionsToClose[1]);
//         assertFalse(positionsToClose[2]);
//         (hasPosition, , ) = curvanceAuxiliaryData.tokenDataOf(
//             users[0],
//             address(cTokens[0])
//         );
//         assertTrue(hasPosition);
//         (hasPosition, , ) = curvanceAuxiliaryData.tokenDataOf(
//             users[0],
//             address(eTokens[0])
//         );
//         assertTrue(hasPosition);
//         (hasPosition, , ) = curvanceAuxiliaryData.tokenDataOf(
//             users[0],
//             address(eTokens[1])
//         );
//         assertTrue(hasPosition);

//         _liquidate(eTokens[0], cTokens[0], users[0], true);

//         (collateralSurplus, liquidityDeficit, positionsToClose) = marketManagerIsolated
//             .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);

//         assertEq(positionsToClose.length, 3);
//         assertFalse(positionsToClose[0]);
//         assertTrue(positionsToClose[1]);
//         assertFalse(positionsToClose[2]);
//         (hasPosition, , ) = curvanceAuxiliaryData.tokenDataOf(
//             users[0],
//             address(cTokens[0])
//         );
//         assertTrue(hasPosition);
//         (hasPosition, , ) = curvanceAuxiliaryData.tokenDataOf(
//             users[0],
//             address(eTokens[0])
//         );
//         assertTrue(hasPosition);
//         (hasPosition, , ) = curvanceAuxiliaryData.tokenDataOf(
//             users[0],
//             address(eTokens[1])
//         );
//         assertTrue(hasPosition);
//         vm.prank(address(eTokens[1]));
//         marketManagerIsolated.canBorrow(address(eTokens[1]), users[0], 0);
//         vm.prank(users[0]);

//         (collateralSurplus, liquidityDeficit, positionsToClose) = marketManagerIsolated
//             .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);

//         assertEq(positionsToClose.length, 2);
//         assertFalse(positionsToClose[0]);
//         assertFalse(positionsToClose[1]);
//         (hasPosition, , ) = curvanceAuxiliaryData.tokenDataOf(
//             users[0],
//             address(cTokens[0])
//         );
//         assertTrue(hasPosition);
//         (hasPosition, , ) = curvanceAuxiliaryData.tokenDataOf(
//             users[0],
//             address(eTokens[0])
//         );
//         assertFalse(hasPosition);
//         (hasPosition, , ) = curvanceAuxiliaryData.tokenDataOf(
//             users[0],
//             address(eTokens[1])
//         );
//         assertTrue(hasPosition);
//     }
// }
