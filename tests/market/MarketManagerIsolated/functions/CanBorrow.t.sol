// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;


import { MarketManagerIsolated, LiquidityManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ILiquidityManager } from "contracts/interfaces/ILiquidityManager.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { AccountSnapshot } from "contracts/interfaces/ICToken.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { console2 } from "forge-std/console2.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract CanBorrowTest is TestBaseMarketIsolated {
    function setUp() public override {
        super.setUp();

        mockUsdcFeed.setMockAnswer(1e8);
        mockWethFeed.setMockAnswer(1500e8);
        mockRethFeed.setMockAnswer(1500e8);
        _refreshMockFeeds();

        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 10_000_000e6);
    }

    function test_canBorrow_fail_whenBorrowPaused() public {
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canBorrow(address(borrowableCUSDC), 100e6, user1, 100e6);
    }

    function test_canBorrow_fail_whenCTokenIsNotListed() public {
        vm.prank(address(borrowableCDAI));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);

        marketManagerIsolated.canBorrow(address(borrowableCUSDC), 100e6, user1, 100e6);
    }

    function test_canBorrow_fail_whenCallerIsNotCToken() public {
        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrow(address(borrowableCDAI), 100e6, user1, 100e6);
    }

    function test_canBorrow_fail_whenInsufficientLiquidity() public {
        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );

        marketManagerIsolated.canBorrow(address(borrowableCUSDC), 100e6, user1, 100e6);
    }

    function test_canBorrow_fail_whenInsufficientLoanSize() public {
        _prepareBALRETH(user1, 1_000e18);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, user1);
        strategyCBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            LiquidityManagerIsolated.LiquidityManager__InsufficientLoanSize.selector
        );
        marketManagerIsolated.canBorrow(address(borrowableCUSDC), 1e6, user1, 1e6);
    }

    function test_canBorrow_fail_userCallsCanBorrow() external {
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrow(address(borrowableCUSDC), 0, user1, 0);
    }

    function test_canBorrow_success_userHasPosition() external {
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100_000e6);

        // Need some cTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(1_000e18, user1);
        strategyCBALRETH.postCollateral(999e18);
        vm.stopPrank();

        bool hasPosition = ILiquidityManager(address(marketManagerIsolated))
            .accountPositions(address(borrowableCUSDC), user1) == 2;

        assertFalse(hasPosition);
        address[] memory accountAssets = marketManagerIsolated.assetsOf(user1);
        assertEq(accountAssets.length, 1);

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrow(
            address(borrowableCUSDC),
            1_000e6,
            user1,
            1_000e6
        );

        hasPosition = ILiquidityManager(address(marketManagerIsolated))
            .accountPositions(address(borrowableCUSDC), user1) == 2;

        assertTrue(hasPosition);

        accountAssets = marketManagerIsolated.assetsOf(user1);
        assertEq(accountAssets.length, 2);
        assertEq(address(accountAssets[0]), address(strategyCBALRETH));
        assertEq(address(accountAssets[1]), address(borrowableCUSDC));
    }

    function test_canBorrow_fail_whenExceedsBorrowCap() external {
        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        vm.prank(address(strategyCBALRETH));
        marketManagerIsolated.canBorrow(
            address(strategyCBALRETH),
            100e6,
            user1,
            100e6
        );
    }

    function test_canBorrow_success_atDebtCapLimit() external {
        _prepareBALRETH(user1, 1_000e18);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, user1);
        strategyCBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrow(
            address(borrowableCUSDC),
            100e6 - 1,
            user1,
            100e6 - 1
        );
    }

    function test_canBorrow_success_atDebtLimit() public {
        _prepareUSDC(address(this), 100e6);
        usdc.approve(address(borrowableCUSDC), 100e6);
        borrowableCUSDC.deposit(100e6, user1);

        vm.prank(address(borrowableCUSDC));
        
        // Need some cTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(1_000e18, user1);
        strategyCBALRETH.postCollateral(999e18);

        borrowableCUSDC.borrow(100e6, user1);

        vm.stopPrank();

        // Get the lower price of USDC
        (uint256 usdcPrice, ) = oracleManager.getPrice(
            address(usdc), // underlying USDC asset
            true,
            false
        );

        (, uint256 maxBorrowAmount, uint256 currentBorrowAmount) = marketManagerIsolated.statusOf(user1);
        console2.log("maxBorrowAmount", maxBorrowAmount);
        console2.log("currentBorrowAmount", currentBorrowAmount);

        uint256 borrowInUSDC = ((maxBorrowAmount - currentBorrowAmount) * 1e6) / usdcPrice;

        console2.log("borrow in usdc", borrowInUSDC);

        // Get the outstanding debt first before the prank
        uint256 currentOutstandingDebt = borrowableCUSDC.marketOutstandingDebt();

        // Borrow the maximum amount possible.
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrow(
            address(borrowableCUSDC),
            borrowInUSDC,
            user1,
            currentOutstandingDebt + borrowInUSDC
        );
    }

    // First borrows 100 usdc, then checks canBorrow for the maximum amount the user can borrow using their collateral - 100 usdc.
    function test_canBorrow_success_atBorrowLimit() public {
        _prepareUSDC(address(this), 100e6);
        usdc.approve(address(borrowableCUSDC), 100e6);
        borrowableCUSDC.deposit(100e6, user1);

        vm.prank(address(borrowableCUSDC));
        
        // Need some cTokens/collateral to have enough liquidity for borrowing
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(1_000e18, user1);
        strategyCBALRETH.postCollateral(999e18);

        borrowableCUSDC.borrow(100e6, user1);

        vm.stopPrank();

        // Get the lower price of USDC
        (uint256 usdcPrice, ) = oracleManager.getPrice(
            address(usdc), // underlying USDC asset
            true,
            false
        );

        (, uint256 maxBorrowAmount, uint256 currentBorrowAmount) = marketManagerIsolated.statusOf(user1);
        console2.log("maxBorrowAmount", maxBorrowAmount);
        console2.log("currentBorrowAmount", currentBorrowAmount);

        uint256 borrowInUSDC = ((maxBorrowAmount - currentBorrowAmount) * 1e6) / usdcPrice;

        console2.log("borrow in usdc", borrowInUSDC);

        // Get the outstanding debt first before the prank
        uint256 currentOutstandingDebt = borrowableCUSDC.marketOutstandingDebt();

        // Borrow the maximum amount possible.
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrow(
            address(borrowableCUSDC),
            borrowInUSDC,
            user1,
            currentOutstandingDebt + borrowInUSDC
        );
    }
}
