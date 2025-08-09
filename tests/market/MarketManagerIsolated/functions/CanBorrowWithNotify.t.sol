// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated, LiquidityManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract CanBorrowWithNotifyTest is TestBaseMarketIsolated {
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
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100e6);
    }

    function test_canBorrowWithNotify_fail_whenCallerIsNotCToken() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            88e6,
            user1,
            88e6
        );
    }

    function test_canBorrowWithNotify_fail_whenCallerCTokenIsNotListedWithNoDebtCapSet()
        public
    {
        vm.prank(address(borrowableCDAI));

        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCDAI),
            88e6,
            user1,
            88e6
        );
    }

    function test_canBorrowWithNotify_fail_whenBorrowPaused() public {
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            88e6,
            user1,
            88e6
        );
    }

    function test_canBorrowWithNotify_fail_whenCTokenIsNotListed() public {
        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCDAI),
            88e6,
            user1,
            88e6
        );
    }

    function test_canBorrowWithNotify_fail_whenCallerIsWrongCTokenAndNotListed()
        public
    {
        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCDAI),
            88e6,
            user1,
            88e6
        );
    }

    function test_canBorrowWithNotify_fail_whenExceedsBorrowCap() external {
        vm.prank(address(strategyCBALRETH));

        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        marketManagerIsolated.canBorrowWithNotify(
            address(strategyCBALRETH),
            100e6 + 1,
            user1,
            100e6 + 1
        );
    }

    function test_canBorrowWithNotify_fail_whenInsufficientCollateral() public {
        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            88e6,
            user1,
            88e6
        );
    }

    function test_canBorrowWithNotify_fail_whenInsufficientLoanSize() public {
        _prepareBALRETH(user1, 1_000e18);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(10e18, user1);
        strategyCBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(LiquidityManagerIsolated.LiquidityManager__InsufficientLoanSize.selector);
        // Borrow below the minimum loan size.
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            1e6,
            user1,
            1e6
        );
    }

    function test_canBorrowWithNotify_success_atDebtCapLimit() external {
        _prepareBALRETH(user1, 1_000e18);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(10e18, user1);
        strategyCBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            100e6 - 1,
            user1,
            100e6 - 1
        );
    }

    function test_canBorrowWithNotify_success_atLoanMinimumSize() public {
        _prepareBALRETH(user1, 1_000e18);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(10e18, user1);
        strategyCBALRETH.postCollateral(10e18);
        vm.stopPrank();

        vm.prank(address(borrowableCUSDC));

        // minimum loan size is 10e6
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            10e6,
            user1,
            10e6
        );
    
        uint256 cooldownTimestamp = marketManagerIsolated.accountAssets(user1);
        uint256 expectedCooldownTimestamp;
        assertEq(cooldownTimestamp, block.timestamp);

        vm.expectRevert(MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector);
        marketManagerIsolated.canRepay(address(borrowableCUSDC), user1);

        vm.warp(block.timestamp + 20 minutes);

        marketManagerIsolated.canRepay(address(borrowableCUSDC), user1);
   
    }

    function test_canBorrowWithNotify_success_withProtocolReaderReview() external {
        _prepareBALRETH(user1, 10_000e18);

        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100_000e6);

        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(1_000e18, user1);
        strategyCBALRETH.postCollateral(999e18);
        vm.stopPrank();

        bool hasPosition;
        (hasPosition, , ) =
            protocolReader.tokenDataOf(user1, address(borrowableCUSDC));

        assertFalse(hasPosition);
        address[] memory accountAssets = marketManagerIsolated.assetsOf(user1);
        assertEq(accountAssets.length, 1);

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrowWithNotify(
            address(borrowableCUSDC),
            1_000e6,
            user1,
            1_000e6
        );

        (hasPosition, , ) =
            protocolReader.tokenDataOf(user1, address(borrowableCUSDC));

        assertTrue(hasPosition);

        accountAssets = marketManagerIsolated.assetsOf(user1);
        assertEq(accountAssets.length, 2);
        assertEq(address(accountAssets[0]), address(strategyCBALRETH));
        assertEq(address(accountAssets[1]), address(borrowableCUSDC));
    }
}
