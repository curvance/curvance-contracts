// // SPDX-License-Identifier: GPL-3.0
// pragma solidity ^0.8.19;

// import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
// 
// import { LiquidationManager } from "contracts/market/LiquidationManager.sol";

// contract LiquidateAccountTest is TestBaseMarketManager {
//     function setUp() public override {
//         super.setUp();
//         _prepareLiquidation();
//     }

//     function test_liquidateAccount_fail_whenLiquidationIsPaused() public {
//         marketManager.setLiquidationPaused(true);

//         vm.expectRevert(MarketManager.MarketManager__Paused.selector);
//         // marketManager.liquidateAccount(user1);
//     }

//     function test_liquidateAccount_fail_whenCallerIsAccount() public {
//         vm.prank(user1);

//         vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
//         // marketManager.liquidateAccount(user1);
//     }

//     function test_liquidateAccount_fail_whenLiquidationsArePaused() public {
//         marketManager.setSeizePaused(true);

//         vm.expectRevert(MarketManager.MarketManager__Paused.selector);
//         // marketManager.liquidateAccount(user1);
//     }

//     function test_liquidateAccount_fail_whenNoLiquidationAvailable() public {
//         vm.prank(user2);

//         vm.expectRevert(
//             MarketManager.MarketManager__NoLiquidationAvailable.selector
//         );
//         // marketManager.liquidateAccount(address(1));
//     }

//     function test_liquidateAccount_success() public {
//         vm.startPrank(user2);

//         usdc.approve(address(borrowableCUSDC), 1000e6);
//         // marketManager.liquidateAccount(user1);

//         vm.stopPrank();

//         _checkLiquidationResult();
//     }

//     function _checkLiquidationResult() internal {
//         assertApproxEqAbs(simpleCBALRETH.balanceOf(user1), 0, 1);
//         assertEq(simpleCBALRETH.exchangeRateCached(), _ONE);

//         assertEq(borrowableCUSDC.balanceOf(user1), 0);
//         assertEq(borrowableCUSDC.debtBalance(user1), 0);
//         assertApproxEqRel(borrowableCUSDC.exchangeRateCached(), _ONE, 0.01e18);
//     }
// }