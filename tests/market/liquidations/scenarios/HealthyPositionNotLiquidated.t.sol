// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { console2 } from "forge-std/console2.sol";


contract HealthyPositionNotLiquidated is TestBaseMarketIsolated {

    address[] borrowers = [user1, makeAddr("attacker")];

    function setUp() public override {
        super.setUp();

        // set up market
        _prepareDAI(address(this), 77777);
        _prepareUSDC(address(this), 10000_000e6 + 77777);

        usdc.approve(address(borrowableCUSDC), 10000_000e6 + 77777);
        dai.approve(address(borrowableCDAI), 77777);

        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        _setCTokenConfigBasic(address(borrowableCUSDC), 10000_000e6, 10000_000e6);
        _setCTokenConfigBasic(address(borrowableCDAI), 10000_000e18, 10000_000e18);

        borrowableCUSDC.deposit(10000_000e6, address(this));

        mockUsdcFeed.setMockAnswer(1e8);
        mockDaiFeed.setMockAnswer(1e8);

        // Set up user positions. Both users start with 1000 DAI collateral. User1 borrows 500 USDC, attacker 250 USDC. 
        for(uint256 i; i < 2;) {
            address user = borrowers[i];
            vm.startPrank(user);
            _prepareDAI(user, 1000e18);
            dai.approve(address(borrowableCDAI), 1000e18);
            borrowableCDAI.depositAsCollateral(1000e18, user);
            borrowableCUSDC.borrow(500e6 / (++i), user);
            vm.stopPrank();
            
        }

        mockDaiFeed.setMockAnswer(70007000);
    }

    function test_fail_NonAuctionLiquidation() public {
        vm.expectRevert(abi.encodeWithSelector(MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector));    
        borrowableCUSDC.liquidate(borrowers, address(borrowableCDAI));
    }

    function test_success_HealthyPositionsNotLiquidatedInAuction() public {
        _prepareUSDC(auctionPermsUser, 1000e6);

        vm.startPrank(auctionPermsUser);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        // Set auction parameters
        uint256 validPenalty = 11500;
        uint256 closeFactor = 3000;
        marketManagerIsolated.setTransientLiquidationConfig(address(borrowableCDAI), validPenalty, closeFactor);
        
        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));
        
        uint256[] memory debtAmounts = new uint256[](2);
        debtAmounts[0] = 150e6;
        debtAmounts[1] = 250e6;

        console2.log("-- Initial states --");
        console2.log("User1 debt: %d", borrowableCUSDC.debtBalance(borrowers[0]));
        console2.log("User1 collateral: %d", borrowableCDAI.collateralPosted(borrowers[0]));
        console2.log("Attacker debt: %d", borrowableCUSDC.debtBalance(borrowers[1]));
        console2.log("Attacker collateral: %d", borrowableCDAI.collateralPosted(borrowers[1]));

        borrowableCUSDC.liquidateExact(debtAmounts, borrowers, address(borrowableCDAI));

        vm.stopPrank();

        console2.log("-- Final states --");
        console2.log("User1 debt: %d", borrowableCUSDC.debtBalance(borrowers[0]));
        console2.log("User1 collateral: %d", borrowableCDAI.collateralPosted(borrowers[0]));
        console2.log("Attacker debt: %d", borrowableCUSDC.debtBalance(borrowers[1]));
        console2.log("Attacker collateral: %d", borrowableCDAI.collateralPosted(borrowers[1]));

        // Assert User1 was liquidated
        assertLt(borrowableCUSDC.debtBalance(borrowers[0]), 500e6, "User1 debt should be liquidated");
        assertLt(borrowableCDAI.collateralPosted(borrowers[0]), 1000e18, "User1 collateral should be liquidated");

        // Assert attacker was NOT liquidated
        assertEq(borrowableCUSDC.debtBalance(borrowers[1]), 250e6, "Attacker debt should be unchanged");
        assertEq(borrowableCDAI.collateralPosted(borrowers[1]), 1000e18, "Attacker collateral should be unchanged");

    }
}