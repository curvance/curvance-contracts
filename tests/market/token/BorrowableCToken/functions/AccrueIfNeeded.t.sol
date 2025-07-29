// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { console2 } from "forge-std/console2.sol";

contract TestAccrueIfNeeded is TestBaseMarketIsolated {

    address daoAddress;

    function setUp() public virtual override {
        super.setUp();

        _prepareUSDC(address(this), 77777);
        _prepareBALRETH(address(this), 77777);
        
        usdc.approve(address(borrowableCUSDC), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        address liquidityProvider = makeAddr("liqProvider");
        _prepareUSDC(liquidityProvider, 100_000e6);

        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 100_000e6);
        borrowableCUSDC.deposit(100_000e6, liquidityProvider);
        vm.stopPrank();

        mockUsdcFeed.setMockAnswer(1e9);
        mockRethFeed.setMockAnswer(2000e9);
        mockWethFeed.setMockAnswer(2000e9);

        daoAddress = centralRegistry.daoAddress();
    }

    function test_success_withProtocolFee() public {
        uint256 borrowAmount = 10_000e6;
        uint256 timeElapsed = 365 days;

        _prepareBALRETH(user1, 100e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 100e18);
        strategyCBALRETH.depositAsCollateral(100e18, user1);
        borrowableCUSDC.borrow(borrowAmount, user1);
        vm.stopPrank();

        skip(timeElapsed);

        borrowableCUSDC.accrueIfNeeded();

        uint256 finalDebt = borrowableCUSDC.debtBalance(user1);

        // uint256 finalDaoShares = borrowableCUSDC.balanceOf(daoAddress);
        // uint256 daoSharesReceived = finalDaoShares - initialDaoShares;

        // uint256 accrualPeriod = borrowableCUSDC.interestRateModel().accrualPeriod();
        // uint256 accruedTime = (timeElapsed / accrualPeriod) * accrualPeriod;
        
        // uint256 totalInterest = (borrowAmount * borrowRate * accruedTime) / WAD;

        // uint256 daoAssetsReceived = (daoSharesReceived * initialTotalAssets) / borrowableCUSDC.totalSupply();
        
        //// assert daoAssetsReceived / totalInterest = protocolFeeRate
        // uint256 actualFeeRate = (daoAssetsReceived * WAD) / totalInterest;
        // assertApproxEqRel(actualFeeRate, protocolFeeRate, 5e16, "dao fee rate should match protocol fee rate");

        // Borrowed 10,000
        // 2% apr = 200 interest over 365 days
        // 200 - 10% = 180
        assertApproxEqAbs(finalDebt, borrowAmount + 180e6, 100, "hard coded user debt wrong"); // (10179999859 vs 10180000000)
        assertApproxEqAbs(borrowableCUSDC.balanceOf(centralRegistry.daoAddress()), 20e6, 1000, "hard coded dao balance wrong"); // (19964049 != 20000000)
    }

    function test_success_withoutProtocolFee() public {
        centralRegistry.setProtocolInterestFee(address(marketManagerIsolated), 0); 
        borrowableCUSDC.setInterestFee(0);

        uint256 borrowAmount = 10_000e6;
        uint256 timeElapsed = 365 days;

        _prepareBALRETH(user1, 100e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 100e18);
        strategyCBALRETH.depositAsCollateral(100e18, user1);
        borrowableCUSDC.borrow(borrowAmount, user1);
        vm.stopPrank();

        uint256 initialDebt = borrowableCUSDC.debtBalance(user1);
        skip(timeElapsed);

        uint256 borrowRate = borrowableCUSDC.interestRateModel().getBorrowRate(
            borrowableCUSDC.assetsHeld(),
            borrowableCUSDC.marketOutstandingDebt()
        );

        borrowableCUSDC.accrueIfNeeded();

        uint256 finalDebt = borrowableCUSDC.debtBalance(user1);
    
        uint256 accrualPeriod = borrowableCUSDC.interestRateModel().accrualPeriod();
        uint256 actualTime = (timeElapsed / accrualPeriod) * accrualPeriod;
        console2.log("actual time", actualTime);
    
        uint256 expectedDebt = initialDebt + (initialDebt * borrowRate * actualTime) / WAD;

        assertEq(finalDebt, expectedDebt, "calculated user debt wrong");
        // Borrowed 10,000
        // 2% apr = 200 interest over 365 days
        // no protocol fee, $100,200
        assertApproxEqAbs(finalDebt, 10_200e6, 100, "hard coded user debt wrong");

        assertEq(borrowableCUSDC.balanceOf(daoAddress), 0, "dao should receive no fees when fee is 0");
    
    }

    function test_noAccrualWhenNoTimeElapsed() public {
        uint256 borrowAmount = 10_000e6;

        _prepareBALRETH(user1, 100e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 100e18);
        strategyCBALRETH.depositAsCollateral(100e18, user1);
        borrowableCUSDC.borrow(borrowAmount, user1);
        vm.stopPrank();

        uint256 initialDebt = borrowableCUSDC.debtBalance(user1);
        uint256 initialDaoShares = borrowableCUSDC.balanceOf(daoAddress);
        uint256 initialTotalAssets = borrowableCUSDC.totalAssets();

        borrowableCUSDC.accrueIfNeeded();

        uint256 finalDebt = borrowableCUSDC.debtBalance(user1);
        uint256 finalDaoShares = borrowableCUSDC.balanceOf(daoAddress);
        uint256 finalTotalAssets = borrowableCUSDC.totalAssets();

        assertEq(finalDebt, initialDebt, "Debt should not change");
        assertEq(finalDaoShares, initialDaoShares, "DAO shares should not change");
        assertEq(finalTotalAssets, initialTotalAssets, "Total assets should not change");
    }
}