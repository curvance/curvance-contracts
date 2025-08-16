// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract CollateralCapsFuzzed is TestBaseMarketIsolated {
    function setUp() override public {
        super.setUp();

        _prepareDAI(address(this), 77777);
        _prepareUSDC(address(this), 77777);

        dai.approve(address(borrowableCDAI), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));
    }

    function test_fuzz_CollateralCaps(uint256 collateralCap, uint256 depositAmount) public {

        collateralCap = bound(collateralCap, 1e18, 1_000_000e18);
        depositAmount = bound(depositAmount, collateralCap / 1000 + 1, collateralCap);

        _setCTokenConfigBasic(address(borrowableCDAI), collateralCap, 1_000_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 10_000_000e6, 1_000_000e6);

        vm.startPrank(user1);

        do {
            _prepareDAI(user1, depositAmount);
            dai.approve(address(borrowableCDAI), depositAmount);
            borrowableCDAI.depositAsCollateral(depositAmount, user1); 
        } while (borrowableCDAI.marketCollateralPosted() + depositAmount <= marketManagerIsolated.collateralCaps(address(borrowableCDAI)));

        _prepareDAI(user1, depositAmount);
        dai.approve(address(borrowableCDAI), depositAmount);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        borrowableCDAI.depositAsCollateral(depositAmount, user1);

        vm.stopPrank();

    }

    function test_fuzz_DebtCaps(uint256 borrowCap, uint256 borrowAmount) public {

        borrowCap = bound(borrowCap, 100_000e18, 1_000_000e18);
        borrowAmount = bound(borrowAmount, borrowCap / 1000 + 1, borrowCap);

        _setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, borrowCap);
        _setCTokenConfigBasic(address(borrowableCUSDC), 10_000_000e6, 1_000_000e6);

        vm.startPrank(user2);
        _prepareDAI(user2, 10_000_000e18);
        dai.approve(address(borrowableCDAI), 10_000_000e18);
        borrowableCDAI.deposit(10_000_000e18, user2);
        vm.stopPrank();

        vm.startPrank(user1);
        _prepareUSDC(user1, 10_000_000e6);
        usdc.approve(address(borrowableCUSDC), 10_000_000e6);
        borrowableCUSDC.depositAsCollateral(10_000_000e6, user1);

        do {
            borrowableCDAI.borrow(borrowAmount, user1);
            skip(20 minutes);
            _refreshMockFeeds();
            borrowableCDAI.accrueIfNeeded();

        } while (borrowableCDAI.marketOutstandingDebt() + borrowAmount <= marketManagerIsolated.debtCaps(address(borrowableCDAI)));

        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        borrowableCDAI.borrow(borrowAmount, user1);

        vm.stopPrank();


    }
}