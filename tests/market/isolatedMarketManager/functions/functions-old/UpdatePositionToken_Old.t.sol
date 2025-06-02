// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.19;

// import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
// import { MarketManager } from "contracts/market/MarketManager.sol";

// contract UpdatePositionTokenTest is TestBaseMarketManager {
//     event PositionTokenUpdated(
//         address mToken,
//         uint256 collRatio,
//         uint256 CollReqSoft,
//         uint256 CollReqHard,
//         uint256 liqIncA,
//         uint256 liqIncB,
//         uint256 baseCFactor
//     );

//     function test_updatePositionToken_fail_whenNotPToken() public {
//         vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
//         marketManager.updatePositionToken(
//             address(eUSDC),
//             9100 + 1,
//             200,
//             300,
//             250,
//             250,
//             1000
//         );
//     }

//     function test_updatePositionToken_fail_whenCallerIsNotAuthorized() public {
//         vm.prank(address(1));

//         vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
//         marketManager.updatePositionToken(
//             address(eUSDC),
//             9000,
//             200,
//             300,
//             250,
//             250,
//             1000
//         );
//     }

//     function test_updatePositionToken_fail_whenLiqIncentiveExceedsMax()
//         public
//     {
//         // when liqInc > _MAX_LIQUIDATION_INCENTIVE
//         marketManager.listToken(address(pBALRETH));
//         vm.expectRevert(
//             MarketManager.MarketManager__InvalidParameter.selector
//         );
//         marketManager.updatePositionToken(
//             address(pBALRETH),
//             9000,
//             200,
//             300,
//             3100, // liqIncA
//             250,
//             1000
//         );
//     }

//     function test_updatePositionToken_fail_whenCollReqSoftExceedsMax() public {
//         // when CollReqSoft > _MAX_COLLATERAL_REQUIREMENT
//         marketManager.listToken(address(pBALRETH));
//         vm.expectRevert(
//             MarketManager.MarketManager__InvalidParameter.selector
//         );
//         marketManager.updatePositionToken(
//             address(pBALRETH),
//             9000,
//             23500, // collReqSoft
//             300,
//             250,
//             250,
//             1000
//         );
//     }

//     function test_updatePositionToken_fail_whenHardCollReqExceedsSoftCollReq()
//         public
//     {
//         // when CollReqHard > CollReqSoft
//         marketManager.listToken(address(pBALRETH));
//         vm.expectRevert(
//             MarketManager.MarketManager__InvalidParameter.selector
//         );
//         marketManager.updatePositionToken(
//             address(pBALRETH),
//             9000,
//             4000, // CollReqSoft - soft liquidation requirement
//             4100,
//             250,
//             250,
//             1000
//         );
//     }

//     function test_updatePositionToken_fail_whenCollRatioExceedsMax() public {
//         // when collRatio > _MAX_COLLATERALIZATION_RATIO
//         marketManager.listToken(address(pBALRETH));
//         vm.expectRevert(
//             MarketManager.MarketManager__InvalidParameter.selector
//         );
//         marketManager.updatePositionToken(
//             address(pBALRETH),
//             9101, // collRatio
//             200,
//             300,
//             250,
//             250,
//             1000
//         );
//     }

//     function test_updatePositionToken_fail_whenCollRatioExceedsPremium()
//         public
//     {
//         // when collRatio > (EXP_SCALE * EXP_SCALE) / (EXP_SCALE + CollReqSoft)
//         marketManager.listToken(address(pBALRETH));
//         vm.expectRevert(
//             MarketManager.MarketManager__InvalidParameter.selector
//         );
//         marketManager.updatePositionToken(
//             address(pBALRETH),
//             9100, // collRatio
//             4000,
//             3000,
//             250,
//             250,
//             1000
//         );
//     }

//     function test_updatePositionToken_fail_whenLiqIncExceedsHardLiquidationRequirement()
//         public
//     {
//         // when liqInc > CollReqHard
//         marketManager.listToken(address(pBALRETH));
//         vm.expectRevert(
//             MarketManager.MarketManager__InvalidParameter.selector
//         );
//         marketManager.updatePositionToken(
//             address(pBALRETH),
//             7000,
//             200,
//             2900,
//             3000,
//             250,
//             1000
//         );
//     }

//     function test_updatePositionToken_fail_whenLiqIncNotEnough() public {
//         // when (liqInc - liqFee) < _MIN_LIQUIDATION_INCENTIVE
//         marketManager.listToken(address(pBALRETH));
//         vm.expectRevert(
//             MarketManager.MarketManager__InvalidParameter.selector
//         );
//         marketManager.updatePositionToken(
//             address(pBALRETH),
//             9100,
//             200,
//             300,
//             10, // liqIncA
//             500, // liqIncB
//             1000
//         );
//     }

//     function test_updatePositionToken_fail_whenMTokenIsNotListed() public {
//         vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
//         marketManager.updatePositionToken(
//             address(pBALRETH),
//             9100,
//             300,
//             200,
//             200,
//             150,
//             1000
//         );
//     }

//     function test_updatePositionToken_fail_whenOracleManagerFails() public {
//         // Set Oracle timestamp to 0 to make price stale
//         mockRethFeed.setMockUpdatedAt(1);

//         marketManager.listToken(address(pBALRETH));
//         vm.expectRevert(MarketManager.MarketManager__PriceError.selector);
//         marketManager.updatePositionToken(
//             address(pBALRETH),
//             7000, // collRatio
//             4000,
//             3000,
//             200,
//             400,
//             1000
//         );
//     }

//     function test_updatePositionToken_success() public {
//         balRETH.approve(address(pBALRETH), 1e18);
//         marketManager.listToken(address(pBALRETH));

//         vm.expectEmit(true, true, true, true, address(marketManager));
//         emit PositionTokenUpdated(
//             address(pBALRETH),
//             0.7e18,
//             0.4e18,
//             0.3e18,
//             0.02e18,
//             0.04e18,
//             0.1e18
//         );

//         marketManager.updatePositionToken(
//             address(pBALRETH),
//             7000, // collRatio
//             4000,
//             3000,
//             200,
//             400,
//             1000
//         );

//         (, uint256 collRatio, , , , , , ) = marketManager.tokenData(
//             address(pBALRETH)
//         );
//         assertEq(collRatio, 0.7e18);
//     }
// }
