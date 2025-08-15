// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { console2 } from "forge-std/console2.sol";

  // This test demonstrates the liquidation buffer functionality in MarketManagerIsolated.
  // The auction system gets priority access to liquidate positions within a 10 basis point window.

  // Setup:
  //    User 1 has 1000 DAI collateral worth $1000 ($1 each)
  //    User 1 borrows 500 USDC ($10 each)
  //    Collateral requirement for soft liquidation: 40% (1.4x multiplier)
  //    Liquidation buffer: 10 basis points (0.1%)

  // Liquidation threshold calculation:
  //    For liquidation: debt * collReqSoft >= collateralValue * WAD
  //    Required: $500 * 1.4 >= collateralValue
  //    Threshold: collateralValue <= $700

  // Test scenario:
  //    DAI price drops to $0.70007 per DAI
  //    Collateral value: 1000 * $0.70007 = $700.07
  //    Regular liquidation lFactor: (500 * 1.4) / 700.07 = 0.9999 < 1.0  (Should fail)
  //    Auction liquidation: applies 10bps buffer (700.07 * 0.999 = $699.37)
  //    Auction lFactor: (500 * 1.4) / 699.37 = 1.0009 > 1.0  (Should succeed)

  // Expected results:
  //    Regular liquidation should fail (MarketManager__NoLiquidationAvailable)
  //    Auction liquidation should succeed with proper collateral seizure
  //    Demonstrates auction system gets priority access in the 10bps window

contract TestLiquidationBuffer is TestBaseMarketIsolated {

    address[] borrowers = [user1];

    function setUp() public override {
        super.setUp();

        // set up market
        _prepareDAI(address(this), 77777);
        _prepareUSDC(address(this), 100_000e6 + 77777);

        usdc.approve(address(borrowableCUSDC), 100_000e18 + 77777);
        dai.approve(address(borrowableCDAI), 77777);

        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e6, 100_000e6);
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        borrowableCUSDC.deposit(100_000e6, address(this));

        mockUsdcFeed.setMockAnswer(1e8);
        mockDaiFeed.setMockAnswer(1e8);

        // Set up user positions
        vm.startPrank(user1);
        _prepareDAI(user1, 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.depositAsCollateral(1000e18, user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        mockDaiFeed.setMockAnswer(70007000);
    }

    function test_fail_NonAuctionLiquidation() public {
        vm.expectRevert(abi.encodeWithSelector(MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector));    
        borrowableCUSDC.liquidate(borrowers, address(borrowableCDAI));
    }

    function test_success_AuctionLiquidation() public {
        _prepareUSDC(auctionPermsUser, 1000e6);

        vm.startPrank(auctionPermsUser);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        // Set auction parameters
        uint256 validPenalty = 11500;
        uint256 closeFactor = 3000;
        marketManagerIsolated.setLiquidationConfig(address(borrowableCDAI), validPenalty, closeFactor);
        
        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));
        marketManagerIsolated.unlockAuctionCollateral(address(borrowableCDAI));
        
        ExpectedLiquidationValues memory expectedLiquidationValues =
            _calculateExpectedLiquidationValues(
                LiquidationParams({
                    borrower: user1,
                    collateralToken: address(borrowableCDAI),
                    borrowedToken: address(borrowableCUSDC),
                    isLiquidateExact: false,
                    liquidateExactAmount: 0,
                    isAuction: true,
                    isMultiMarketTest: false,
                    marketManagerId: 0
                })
            );

        borrowableCUSDC.liquidate(borrowers, address(borrowableCDAI));

        vm.stopPrank();

        assertEq(borrowableCUSDC.debtBalanceUpdated(user1),
            500e6 - expectedLiquidationValues.debtRepaid, " debt balance should have changed");

        assertEq(borrowableCDAI.balanceOf(user1), 1000e18 -
            expectedLiquidationValues.collateralLiquidated, " collateral balance should have changed");
        
        assertEq(borrowableCDAI.balanceOf(auctionPermsUser), 
            expectedLiquidationValues.collateralLiquidated, " debt balance should have changed");

    }
}