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
        marketManagerIsolated.setTransientLiquidationConfig(address(borrowableCDAI), validPenalty, closeFactor);
        
        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));
        
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

    function test_success_AuctionLiquidationWithZeroValues() public {
        _prepareUSDC(auctionPermsUser, 1000e6);

        // First verify that without auction (no buffer), liquidation would fail
        // This proves the auction buffer makes the difference
        vm.expectRevert(abi.encodeWithSelector(MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector));
        borrowableCUSDC.liquidate(borrowers, address(borrowableCDAI));

        vm.startPrank(auctionPermsUser);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        // Set auction parameters with ZERO to use protocol-derived values
        marketManagerIsolated.setTransientLiquidationConfig(address(borrowableCDAI), 0, 0);

        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));

        // Verify zeros are stored in transient config
        (, uint256 storedIncentive, uint256 storedCloseFactor) = marketManagerIsolated.getTransientLiquidationConfig();
        assertEq(storedIncentive, 0, "Incentive should be stored as 0");
        assertEq(storedCloseFactor, 0, "Close factor should be stored as 0");

        // Capture state before liquidation
        uint256 debtBefore = borrowableCUSDC.debtBalanceUpdated(user1);
        uint256 collateralBefore = borrowableCDAI.balanceOf(user1);

        // This liquidation succeeds because:
        // 1. Auction buffer (9990) is applied even with zero values
        // 2. Protocol-derived dynamic liquidation incentive and close factor are used
        borrowableCUSDC.liquidate(borrowers, address(borrowableCDAI));

        vm.stopPrank();

        // Verify liquidation occurred - debt was reduced
        uint256 debtAfter = borrowableCUSDC.debtBalanceUpdated(user1);
        assertLt(debtAfter, debtBefore, "Debt should have been reduced");

        // Verify collateral was seized
        uint256 collateralAfter = borrowableCDAI.balanceOf(user1);
        assertLt(collateralAfter, collateralBefore, "Collateral should have been seized");

        // Verify liquidator received collateral
        uint256 liquidatorCollateral = borrowableCDAI.balanceOf(auctionPermsUser);
        assertGt(liquidatorCollateral, 0, "Liquidator should have received collateral");

        uint256 debtRepaid = debtBefore - debtAfter;
        uint256 collateralSeized = collateralBefore - collateralAfter;

        console2.log("Debt repaid with zeros:", debtRepaid);
        console2.log("Collateral seized with zeros:", collateralSeized);

    }

    function test_success_AuctionLiquidationWithPartialZeroValues() public {
        _prepareUSDC(auctionPermsUser, 1000e6);

        vm.startPrank(auctionPermsUser);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        // Set auction with lower non-zero incentive but zero close factor
        // liqIncMin = 10, so use 10500 (105%) which is lower than protocol-derived
        // Lower incentive = less collateral seized per unit debt
        uint256 lowerIncentive = 10500;
        marketManagerIsolated.setTransientLiquidationConfig(address(borrowableCDAI), lowerIncentive, 0);

        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));

        // Verify values are stored correctly
        (, uint256 storedIncentive, uint256 storedCloseFactor) = marketManagerIsolated.getTransientLiquidationConfig();
        assertEq(storedIncentive, lowerIncentive, "Custom lower incentive should be stored");
        assertEq(storedCloseFactor, 0, "Close factor should be stored as 0");

        // Capture state before liquidation
        uint256 debtBefore = borrowableCUSDC.debtBalanceUpdated(user1);
        uint256 collateralBefore = borrowableCDAI.balanceOf(user1);

        // Execute liquidation with custom lower incentive + protocol-derived close factor
        borrowableCUSDC.liquidate(borrowers, address(borrowableCDAI));

        vm.stopPrank();

        // Verify liquidation occurred
        uint256 debtAfter = borrowableCUSDC.debtBalanceUpdated(user1);
        uint256 collateralAfter = borrowableCDAI.balanceOf(user1);
        uint256 liquidatorCollateral = borrowableCDAI.balanceOf(auctionPermsUser);

        uint256 debtRepaid = debtBefore - debtAfter;
        uint256 collateralSeized = collateralBefore - collateralAfter;

        assertGt(debtRepaid, 0, "Debt should have been repaid");
        assertGt(collateralSeized, 0, "Collateral should have been seized");
        assertEq(liquidatorCollateral, collateralSeized, "Liquidator should have received seized collateral");

        // With lower incentive, less collateral should be seized than the all-zeros test
        // All-zeros test seized 164508299170082991700 (with protocol-derived incentive)
        uint256 collateralSeizedWithZeros = 164508299170082991700;
        assertLt(collateralSeized, collateralSeizedWithZeros,
            "Lower incentive (105%) should result in less collateral seized than protocol-derived incentive (~110%)");

    }
}