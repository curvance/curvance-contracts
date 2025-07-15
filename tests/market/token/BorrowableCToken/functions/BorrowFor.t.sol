// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract BorrowableCTokenBorrowTest is TestBaseBorrowableCToken {
    event Borrow(uint256 borrowAmount, address borrower);

    function test_borrowableCTokenBorrowFor_fail_whenBorrowIsNotAllowed() public {
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);

        _delegateToUser();

        vm.prank(user2);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCUSDC.borrowFor(100e6, user2, user1);

        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowFor_fail_whenDelegationIsNotApproved() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        _provideLiquidity();
        _depositCollateral();

        vm.prank(user2);

        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        borrowableCUSDC.borrowFor(100e6, user1, user1);

        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowFor_fail_whenBorrowAmountExceedsAssetsHeld() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        _provideLiquidity();
        _depositCollateral();
        _delegateToUser();

        skip(69 minutes);

        uint256 assetsHeld = borrowableCUSDC.assetsHeld();

        vm.prank(user2);

        vm.expectRevert(
            BorrowableCToken.BorrowableCToken__InsufficientAssetsHeld.selector
        );
        borrowableCUSDC.borrowFor(assetsHeld + 1, user2, user1);

        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowFor_fail_whenBorrowAmountExceedsDebtCap() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        _provideLiquidity();
        _depositCollateral();
        _delegateToUser();

        skip(69 minutes);

        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 0);

        vm.prank(user2);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        borrowableCUSDC.borrowFor(100e6, user2, user1);
        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowFor_fail_whenCollateralPostedInBorrowableCToken() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        _provideLiquidity();
        _depositCollateral();
        _delegateToUser();

        // Provide liquidity in borrowable cUSDC.
        vm.prank(user1);
        _prepareUSDC(user1, 10e6);
        usdc.approve(address(borrowableCUSDC), 10e6);
        borrowableCUSDC.depositAsCollateral(10e6, user1);
        vm.stopPrank();

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

        _provideLiquidity();
        _depositCollateral();
        _delegateToUser();

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

        _provideLiquidity();
        _depositCollateral();
        _delegateToUser();

        uint256 underlyingBalance = usdc.balanceOf(user2);
        uint256 balance = borrowableCUSDC.balanceOf(user2);
        uint256 totalSupply = borrowableCUSDC.totalSupply();
        uint256 totalDebt = borrowableCUSDC.marketOutstandingDebt();

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
        vm.prank(user1);
        borrowableCUSDC.setDelegateApproval(user2, true);
        vm.stopPrank();
    }

    function _provideLiquidity() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 100e6);

        // Mint borrowableCUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 100e6);
        borrowableCUSDC.deposit(100e6, liquidityProvider);
        vm.stopPrank();
    }

    function _depositCollateral() internal {
        _prepareBALRETH(user1, 10e18);

        // Mint and collateralize strategyCBALRETH.
        vm.prank(user1);
        balRETH.approve(address(strategyCBALRETH), 1e18);
        strategyCBALRETH.depositAsCollateral(1e18,  user1);
        vm.stopPrank();
    }
}
