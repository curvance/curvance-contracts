// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { console2 } from "forge-std/console2.sol";

contract TestAccrueIfNeeded is TestBaseMarketIsolated {

    address daoAddress;
    address liquidityProvider;

    function setUp() public virtual override {
        super.setUp();

        _prepareUSDC(address(this), 77777);
        _prepareBALRETH(address(this), 77777);
        
        usdc.approve(address(borrowableCUSDC), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        liquidityProvider = makeAddr("liqProvider");
        _prepareUSDC(liquidityProvider, 100_000e6);

        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, liquidityProvider);
        vm.stopPrank();

        mockUsdcFeed.setMockAnswer(1e9);
        mockRethFeed.setMockAnswer(2000e9);
        mockWethFeed.setMockAnswer(2000e9);

        daoAddress = centralRegistry.daoAddress();
    }
    
    function test_success_accrueIfNeeded_singleVestingPeriod() public {

        _prepareBALRETH(user1, 250e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 250e18);
        strategyCBALRETH.depositAsCollateral(250e18, user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        (,uint256 initialVestEnd,) = borrowableCUSDC.getYieldInformation();
        console2.log("initialVestEnd: ", initialVestEnd);

        // Skip to trigger first vesting period
        skip(5 minutes);
        borrowableCUSDC.accrueIfNeeded();

        (,uint256 midVestEnd, uint256 midLastVest) = borrowableCUSDC.getYieldInformation();

        assertEq(midVestEnd, initialVestEnd + 600, "First vesting period should advance by 600 seconds");
        assertEq(midLastVest, block.timestamp, "Last vest claim should update to current timestamp");

        // Skip to trigger second vesting period
        skip(5 minutes + 1 seconds);
        borrowableCUSDC.accrueIfNeeded();

        (,uint256 finalVestEnd,) = borrowableCUSDC.getYieldInformation();
        console2.log("finalVestEnd: ", finalVestEnd);
        
        assertEq(finalVestEnd - initialVestEnd, 1200, "Should advance by exactly 1200 seconds total");

    }

    function test_success_accrueIfNeeded_multipleVestingPeriods() public {

        _prepareBALRETH(user1, 250e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 250e18);
        strategyCBALRETH.depositAsCollateral(250e18, user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        (,uint256 initialVestEnd,) = borrowableCUSDC.getYieldInformation();
        uint256 initialMarketDebt = borrowableCUSDC.marketOutstandingDebt();
        console2.log("initialMarketDebt: ", initialMarketDebt);
        console2.log("initialVestEnd: ", initialVestEnd);
        
        // Skip 2.5 periods
        skip(25 minutes);
        borrowableCUSDC.accrueIfNeeded();

        (,uint256 finalVestEnd,) = borrowableCUSDC.getYieldInformation();
        console2.log("finalVestEnd: ", finalVestEnd);

        assertEq(finalVestEnd - initialVestEnd, 1800, "Should advance by 3 full periods");
        
    }

    function test_success_accrueIfNeeded_noTimeElapsed() public {

        _prepareBALRETH(user1, 250e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 250e18);
        strategyCBALRETH.depositAsCollateral(250e18, user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        (uint256 beforeRate, uint256 beforeVestEnd, uint256 beforeLastVest) = borrowableCUSDC.getYieldInformation();
        uint256 beforeDebt = borrowableCUSDC.marketOutstandingDebt();
        console2.log("beforeDebt: ", beforeDebt);
        console2.log("beforeVestEnd: ", beforeVestEnd);

        borrowableCUSDC.accrueIfNeeded();

        (uint256 afterRate, uint256 afterVestEnd, uint256 afterLastVest) = borrowableCUSDC.getYieldInformation();
        uint256 afterDebt = borrowableCUSDC.marketOutstandingDebt();

        assertEq(afterRate, beforeRate, "Interest rate should not change");
        assertEq(afterDebt, beforeDebt, "Outstanding debt should not change");
        assertEq(afterVestEnd, beforeVestEnd, "Vesting end should not change");
        assertEq(afterLastVest, beforeLastVest, "Last vest claim should not change");
    }

    function test_success_accrueIfNeeded_vestingPeriodTransition() public {

        _prepareBALRETH(user1, 250e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 250e18);
        strategyCBALRETH.depositAsCollateral(250e18, user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        // at block.timestamp
        (,uint256 initialVestEnd,) = borrowableCUSDC.getYieldInformation();
        uint256 initialMarketDebt = borrowableCUSDC.marketOutstandingDebt();
        
        // Get interest rate
        uint256 borrowRate = borrowableCUSDC.interestRateModel().getBorrowRate(
            borrowableCUSDC.assetsHeld(),
            initialMarketDebt
        );

        // Skip exactly one vesting period
        skip(10 minutes);
        borrowableCUSDC.accrueIfNeeded();

        (,uint256 midVestEnd, uint256 midLastVest) = borrowableCUSDC.getYieldInformation();
        uint256 midMarketDebt = borrowableCUSDC.marketOutstandingDebt();

        // Should advance by 2 periods,1200 seconds 
        assertEq(midVestEnd, initialVestEnd + 1200, "Should advance by 1200 seconds");
        assertEq(midLastVest, block.timestamp, "Last vest should update to current timestamp");
        
        // Validate yield calculation for first 10 minutes
        uint256 timeElapsed = 10 minutes;  
        uint256 expectedYield = (initialMarketDebt * borrowRate * timeElapsed) / 1e18;
        uint256 actualYield = midMarketDebt - initialMarketDebt;
        assertEq(actualYield, expectedYield, "First period yield should match calculated yield");

        // Get updated interest rate after first accrual
        borrowRate = borrowableCUSDC.interestRateModel().getBorrowRate(
            borrowableCUSDC.assetsHeld(),
            midMarketDebt
        );

        // skip 1 second, should not trigger new period
        skip(1 seconds);
        borrowableCUSDC.accrueIfNeeded();

        (,uint256 finalVestEnd, uint256 finalLastVest) = borrowableCUSDC.getYieldInformation();
        uint256 finalMarketDebt = borrowableCUSDC.marketOutstandingDebt();

        assertEq(finalVestEnd - initialVestEnd, 1200, "Should remain at 1200 seconds total");
        assertEq(finalLastVest, block.timestamp, "Last vest should update to current timestamp");
        console2.log("midMarketDebt: ", midMarketDebt);
        console2.log("finalMarketDebt: ", finalMarketDebt);

        // Validate yield calculation for additional 1 second
        timeElapsed = 1 seconds;  
        expectedYield = (midMarketDebt * borrowRate * timeElapsed) / 1e18;
        actualYield = finalMarketDebt - midMarketDebt;
        assertEq(actualYield, expectedYield, "Second period yield should match calculated yield with updated rate");
    }

    function test_success_accrueIfNeeded_verifyAccountingAllParties() public {

        _prepareBALRETH(user1, 250e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 250e18);
        strategyCBALRETH.depositAsCollateral(250e18, user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        uint256 testContractShares = borrowableCUSDC.balanceOf(address(this));
        uint256 lpShares = borrowableCUSDC.balanceOf(liquidityProvider); 
        uint256 totalAssets = borrowableCUSDC.totalAssets();
        uint256 totalShares = borrowableCUSDC.totalSupply();
        console2.log("testContractShares: ", testContractShares);
        
        // LP deposited 1000e6, + 77777 initialization deposit
        assertEq(totalAssets, 1000e6 + 77777, "Total assets should be lp deposit plus initialization");
        assertEq(lpShares, 1000e6, "LP should have shares equal to their deposit");
        assertEq(totalShares, 1000e6 + 77777, "Total shares should equal total assets initially");
        assertEq(borrowableCUSDC.debtBalance(user1), 500e6, "Borrower should have initial debt");

        uint256 beforeMarketDebt = borrowableCUSDC.marketOutstandingDebt();
        
        // Get interest rate for yield validation
        uint256 borrowRate = borrowableCUSDC.interestRateModel().getBorrowRate(
            borrowableCUSDC.assetsHeld(),
            beforeMarketDebt
        );

        // trigger vesting period
        skip(10 minutes);
        borrowableCUSDC.accrueIfNeeded();

        uint256 afterAssets = borrowableCUSDC.totalAssets();
        uint256 afterShares = borrowableCUSDC.totalSupply();
        uint256 afterDaoShares = borrowableCUSDC.balanceOf(daoAddress);
        uint256 afterMarketDebt = borrowableCUSDC.marketOutstandingDebt();

        // calculate expected values
        uint256 assetIncrease = afterAssets - totalAssets;
        uint256 shareIncrease = afterShares - totalShares;
        uint256 debtIncrease = afterMarketDebt - beforeMarketDebt;

        assertEq(assetIncrease, debtIncrease, "asset increase should equal debt increase");
        assertEq(shareIncrease, afterDaoShares, "Only dao should receive new shares");
        
        // assert yield calculation
        uint256 timeElapsed = 10 minutes;  
        uint256 expectedYield = (beforeMarketDebt * borrowRate * timeElapsed) / 1e18;
        assertEq(assetIncrease, expectedYield, "actual yield should match calculated yield");
        
        // dao gets 10% of interest as new shares
        uint256 expectedProtocolFee = (assetIncrease * 1000) / 10000;
        uint256 actualProtocolFee = borrowableCUSDC.convertToAssets(afterDaoShares);  
        assertEq(actualProtocolFee, expectedProtocolFee, "Protocol fee should be 10% of interest");
        
        // LP gets their 90% through increased exchange value
        uint256 lpValueIncrease = borrowableCUSDC.convertToAssets(1000e6) - 1000e6;
        uint256 expectedLpIncrease = (assetIncrease * 9000) / 10000;
        assertEq(lpValueIncrease, expectedLpIncrease, "LP should get 90% of interest");

        assertEq(borrowableCUSDC.debtBalance(user1), 500e6 + assetIncrease, "Borrower debt should increase by total interest amount");
        assertEq(borrowableCUSDC.balanceOf(liquidityProvider), 1000e6, "LP shares should not change");
    }

    // More targeted assertions for dao
    function test_success_accrueIfNeeded_protocolFeeAccounting() public {

        _prepareBALRETH(user1, 250e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 250e18);
        strategyCBALRETH.depositAsCollateral(250e18, user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        uint256 initialDaoShares = borrowableCUSDC.balanceOf(daoAddress);
        uint256 initialTotalShares = borrowableCUSDC.totalSupply();
        uint256 initialTotalAssets = borrowableCUSDC.totalAssets();
        uint256 initialMarketDebt = borrowableCUSDC.marketOutstandingDebt();
        
        // Get current interest rate
        uint256 borrowRate = borrowableCUSDC.interestRateModel().getBorrowRate(
            borrowableCUSDC.assetsHeld(),
            initialMarketDebt
        );

        console2.log("BorrowRate: ", borrowRate);

        // Skip 3 vesting periods to accumulate more interest
        skip(30 minutes);
        borrowableCUSDC.accrueIfNeeded();

        uint256 finalDaoShares = borrowableCUSDC.balanceOf(daoAddress);
        uint256 finalTotalShares = borrowableCUSDC.totalSupply();
        uint256 finalTotalAssets = borrowableCUSDC.totalAssets();
        uint256 finalMarketDebt = borrowableCUSDC.marketOutstandingDebt();

        // Calculate expected values
        uint256 daoSharesIncrease = finalDaoShares - initialDaoShares;
        uint256 totalSharesIncrease = finalTotalShares - initialTotalShares;
        uint256 totalAssetsIncrease = finalTotalAssets - initialTotalAssets;
        uint256 marketDebtIncrease = finalMarketDebt - initialMarketDebt;

        assertEq(totalAssetsIncrease, marketDebtIncrease, "Asset increase must equal debt increase");
        assertEq(totalSharesIncrease, daoSharesIncrease, "Only dao receives new shares");

        uint256 timeElapsed = 30 minutes;  
        uint256 expectedYield = (initialMarketDebt * borrowRate * timeElapsed) / 1e18;
        assertEq(totalAssetsIncrease, expectedYield, "Actual yield should match calculated yield");

        // dao gets exactly 10% of interest as new shares
        uint256 protocolFeeAssetValue = borrowableCUSDC.convertToAssets(daoSharesIncrease);
        uint256 expectedProtocolFee = (totalAssetsIncrease * 1000) / 10000;
        
        assertEq(protocolFeeAssetValue, expectedProtocolFee,"Protocol fee should be exactly 10% of interest");
        
    }

    function test_success_accrueIfNeeded_noProtocolFee() public {

        // set protocol fee to 0
        borrowableCUSDC.setInterestFee(0);

        _prepareBALRETH(user1, 250e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 250e18);
        strategyCBALRETH.depositAsCollateral(250e18, user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        uint256 initialTotalShares = borrowableCUSDC.totalSupply();
        uint256 initialTotalAssets = borrowableCUSDC.totalAssets();
        uint256 initialLpShares = borrowableCUSDC.balanceOf(liquidityProvider);
        uint256 initialMarketDebt = borrowableCUSDC.marketOutstandingDebt();
        
        // Get interest rate for yield validation
        uint256 borrowRate = borrowableCUSDC.interestRateModel().getBorrowRate(
            borrowableCUSDC.assetsHeld(),
            initialMarketDebt
        );

        skip(30 minutes);
        borrowableCUSDC.accrueIfNeeded();

        uint256 finalDaoShares = borrowableCUSDC.balanceOf(daoAddress);
        uint256 finalTotalShares = borrowableCUSDC.totalSupply();
        uint256 finalTotalAssets = borrowableCUSDC.totalAssets();
        uint256 finalLpShares = borrowableCUSDC.balanceOf(liquidityProvider);
        uint256 finalMarketDebt = borrowableCUSDC.marketOutstandingDebt();

        // Calculate changes
        uint256 totalAssetsIncrease = finalTotalAssets - initialTotalAssets;
        uint256 marketDebtIncrease = finalMarketDebt - initialMarketDebt;
        assertEq(totalAssetsIncrease, marketDebtIncrease, "Asset increase must equal debt increase");

        // assert yield calculation
        uint256 timeElapsed = 30 minutes;  
        uint256 expectedYield = (initialMarketDebt * borrowRate * timeElapsed) / 1e18;
        assertEq(totalAssetsIncrease, expectedYield, "Actual yield should match calculated yield");

        // Total shares should not increase
        assertEq(finalDaoShares, 0, "dao should still have no shares with 0% fee");
        assertEq(finalLpShares, initialLpShares, "LP share count should not change");
        assertEq(finalTotalShares, initialTotalShares, "Total shares should remain unchanged");
        
        uint256 lpValueIncrease = borrowableCUSDC.convertToAssets(finalLpShares) - 1000e6;

        // Off by one because pool initilization deposits 77777 to total assets/shares
        assertEq(lpValueIncrease, totalAssetsIncrease - 1, "LP should receive proportional share of interest");

        // Borrower debt increases by total interest
        uint256 borrowerDebtIncrease = borrowableCUSDC.debtBalance(user1) - 500e6;
        assertEq(borrowerDebtIncrease, totalAssetsIncrease, "Borrower debt should increase by total interest");
    }

    function test_success_accrueIfNeeded_loopedVestingPeriods() public {

        // Add more liquidity
        _prepareUSDC(liquidityProvider, 100_000e6);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 50000e6);
        borrowableCUSDC.deposit(50000e6, liquidityProvider);
        vm.stopPrank();

        _prepareBALRETH(user1, 2500e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 2500e18);
        strategyCBALRETH.depositAsCollateral(2500e18, user1);
        borrowableCUSDC.borrow(25000e6, user1);
        vm.stopPrank();

        // cache initial values
        uint256 initialMarketDebt = borrowableCUSDC.marketOutstandingDebt();
        uint256 initialTotalAssets = borrowableCUSDC.totalAssets();
        uint256 initialDaoShares = borrowableCUSDC.balanceOf(daoAddress);
        (,uint256 initialVestEnd,) = borrowableCUSDC.getYieldInformation();
        
        uint256 borrowRate = borrowableCUSDC.interestRateModel().getBorrowRate(
            borrowableCUSDC.assetsHeld(),
            initialMarketDebt
        );

        // Loop 20 times, skipping 5 minutes each loop, 100 minutes total
        uint256 previousMarketDebt = initialMarketDebt;
        uint256 previousDaoShares = initialDaoShares;
        uint256 previousLpValue = borrowableCUSDC.convertToAssets(borrowableCUSDC.balanceOf(liquidityProvider));
        
        for (uint256 i = 0; i < 20; i++) {
            console2.log("i", i);
            skip(5 minutes);
            
            // Get current interest rate before accrual
            uint256 currentBorrowRate = borrowableCUSDC.interestRateModel().getBorrowRate(
                borrowableCUSDC.assetsHeld(),
                previousMarketDebt
            );
            
            borrowableCUSDC.accrueIfNeeded();
            
            // Validate this iteration
            uint256 currentMarketDebt = borrowableCUSDC.marketOutstandingDebt();
            uint256 currentDaoShares = borrowableCUSDC.balanceOf(daoAddress);
            
            uint256 debtIncrease = currentMarketDebt - previousMarketDebt;
            uint256 daoSharesIncrease = currentDaoShares - previousDaoShares;
            
            // Expected yield for this 5-minute period
            uint256 expectedYield = (previousMarketDebt * currentBorrowRate * 5 minutes) / 1e18;
            
            // assert yield
            assertEq(debtIncrease, expectedYield, "Yield should match for loop");
            
            // assert protocol fee
            uint256 protocolFeeValue = borrowableCUSDC.convertToAssets(daoSharesIncrease);
            uint256 expectedProtocolFee = (debtIncrease * 1000) / 10000;
            assertEq(protocolFeeValue, expectedProtocolFee, "Protocol fee should be exactly 10% per loop");
            
            // assert LP value increase
            uint256 currentLpValue = borrowableCUSDC.convertToAssets(borrowableCUSDC.balanceOf(liquidityProvider));
            uint256 lpValueIncrease = currentLpValue - previousLpValue;
            uint256 expectedLpIncrease = (debtIncrease * 90000) / 100000;
            assertEq(lpValueIncrease, expectedLpIncrease, "LP should get exactly 90% per loop");
            
            // update for next iteration
            previousMarketDebt = currentMarketDebt;
            previousDaoShares = currentDaoShares;
            previousLpValue = currentLpValue;
        }

        uint256 finalMarketDebt = borrowableCUSDC.marketOutstandingDebt();
        uint256 finalTotalAssets = borrowableCUSDC.totalAssets();
        uint256 finalDaoShares = borrowableCUSDC.balanceOf(daoAddress);
        (,uint256 finalVestEnd,) = borrowableCUSDC.getYieldInformation();

        // validate vesting period, 100 minutes + initial period = 11 periods
        assertEq(finalVestEnd - initialVestEnd, 6600, "Should advance by 11 full vesting periods");

        // Calculate changes
        uint256 totalAssetsIncrease = finalTotalAssets - initialTotalAssets;
        uint256 marketDebtIncrease = finalMarketDebt - initialMarketDebt;
        uint256 daoSharesIncrease = finalDaoShares - initialDaoShares;

        // Assert debt asset and debt increase
        assertEq(totalAssetsIncrease, marketDebtIncrease, "Asset increase must equal debt increase");

        // borrower debt increase
        assertEq(borrowableCUSDC.debtBalance(user1), 25000e6 + totalAssetsIncrease, "Borrower debt should increase by total interest");
    }
}