// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract BorrowableCTokenBorrowTest is TestBaseBorrowableCToken {
    event Borrow(uint256 borrowAmount, address borrower);

    function test_borrowableCTokenBorrowFor_fail_whenBorrowIsNotAllowed() public {
        address borrower = makeAddr("borrower");
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);

        vm.prank(user1);
        _delegateToUser();
        vm.stopPrank();
        vm.prank(user2);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCUSDC.borrowFor(100e6, user2, user1);

        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowFor_fail_whenDelegationIsNotApproved() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        vm.prank(user1);

        borrowableCUSDC.deposit(200e6, user1);

        strategyCBALRETH.postCollateral(1e18 - 1);

        vm.stopPrank();

        vm.prank(user2);

        // bytes4(keccak256(bytes("PluginDelegable__Unauthorized()")))
        vm.expectRevert(0xcfdc5602);
        borrowableCUSDC.borrowFor(100e6, user1, user1);

        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowFor_fail_whenBorrowAmountExceedsAssetsHeld() public {
        address liquidityProvider = makeAddr("liquidityProvider");

        _prepareUSDC(liquidityProvider, 100e6);
        // Mint borrowableCUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 100e6);
        borrowableCUSDC.deposit(100e6, liquidityProvider);
        vm.stopPrank();

        vm.prank(user1);
        _delegateToUser();
        
        _prepareBALRETH(user1, _ONE);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        skip(69 minutes);

        uint256 assetsHeld = borrowableCUSDC.assetsHeld();

        vm.stopPrank();
        vm.prank(user2);

        vm.expectRevert(
            BorrowableCToken.BorrowableCToken__InsufficientAssetsHeld.selector
        );
        borrowableCUSDC.borrowFor(assetsHeld + 1, user2, user1);

        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowFor_fail_whenBorrowAmountExceedsDebtCap() public {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 100e6);
        // mint borrowableCUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 100e6);
        borrowableCUSDC.deposit(100e6, liquidityProvider);
        vm.stopPrank();

        vm.prank(user1);
        _delegateToUser();
        
        _prepareBALRETH(user1, _ONE);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);

        skip(69 minutes);
        vm.stopPrank();

        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 0);

        vm.prank(user2);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        borrowableCUSDC.borrowFor(100e6, user2, user1);
        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowFor_fail_whenCollateralPostedInBorrowableCToken() public {

        vm.prank(user1);
        borrowableCUSDC.deposit(200e6, user1);

        strategyCBALRETH.postCollateral(1e18 - 1);
        borrowableCUSDC.postCollateral(100e6 - 1);

        _delegateToUser();
        vm.stopPrank();
        vm.prank(user2);

        vm.expectRevert(
            BorrowableCToken.BorrowableCToken__InvalidParameter.selector
        );

        borrowableCUSDC.borrowFor(20e6, user2, user1);
        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowForSendToDelegater_success() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        vm.prank(user1);

        borrowableCUSDC.deposit(200e6, user1);

        strategyCBALRETH.postCollateral(1e18 - 1);

        uint256 underlyingBalance = usdc.balanceOf(user1);
        uint256 balance = borrowableCUSDC.balanceOf(user1);
        uint256 totalSupply = borrowableCUSDC.totalSupply();
        uint256 totalDebt = borrowableCUSDC.marketOutstandingDebt();

        _delegateToUser();
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Borrow(100e6, user1);

        vm.prank(user2);
        borrowableCUSDC.borrowFor(100e6, user1, user1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), underlyingBalance + 100e6);
        assertEq(borrowableCUSDC.balanceOf(user1), balance);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), totalDebt + 100e6);
    }

    function test_borrowableCTokenBorrowForSendToDelegatee_success() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        vm.prank(user1);

        borrowableCUSDC.deposit(200e6, user1);

        strategyCBALRETH.postCollateral(1e18 - 1);

        uint256 underlyingBalance = usdc.balanceOf(user2);
        uint256 balance = borrowableCUSDC.balanceOf(user2);
        uint256 totalSupply = borrowableCUSDC.totalSupply();
        uint256 totalDebt = borrowableCUSDC.marketOutstandingDebt();

        _delegateToUser();
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Borrow(100e6, user1);

        vm.prank(user2);
        borrowableCUSDC.borrowFor(100e6, user2, user1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user2), underlyingBalance + 100e6);
        assertEq(borrowableCUSDC.balanceOf(user2), balance);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), totalDebt + 100e6);
    }

    function _delegateToUser() internal {
        borrowableCUSDC.setDelegateApproval(user2, true);
    }
}
