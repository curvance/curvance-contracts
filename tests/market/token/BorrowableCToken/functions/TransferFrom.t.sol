// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract BorrowableCTokenTransferFromTest is TestBaseBorrowableCToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_borrowableCTokenTransferFrom_fail_whenSenderAndReceiverAreSame()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__TransferError.selector);
        borrowableCUSDC.transferFrom(address(this), address(this), 100e6);
    }

    function test_borrowableCTokenTransferFrom_fail_whenTransferZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        borrowableCUSDC.transferFrom(address(this), user1, 0);
    }

    function test_borrowableCTokenTransferFrom_fail_whenAllowanceIsInvalid() public {
        vm.expectRevert();
        borrowableCUSDC.transferFrom(user1, address(this), 100e6);
    }

    function test_transfer_fail_whenTransferIsNotAllowed() public {
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCUSDC.transferFrom(address(this), user1, 100e6);
    }

    function test_borrowableCTokenTransferFrom_success_whenRedemptionsPaused() public {
        deal(address(borrowableCUSDC), address(this), 100e6);

        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 user1Balance = borrowableCUSDC.balanceOf(user1);

        borrowableCUSDC.approve(user1, 100e6);

        // Pause redemptions which should not impact transfer actions.
        marketManagerIsolated.setRedeemPaused(true);

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Transfer(address(this), user1, 100e6);

        vm.prank(user1);
        borrowableCUSDC.transferFrom(address(this), user1, 100e6);

        assertEq(borrowableCUSDC.balanceOf(address(this)), balance - 100e6);
        assertEq(borrowableCUSDC.balanceOf(user1), user1Balance + 100e6);
    }

    function test_borrowableCTokenTransferFrom_success() public {
        deal(address(borrowableCUSDC), address(this), 100e6);

        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 user1Balance = borrowableCUSDC.balanceOf(user1);

        borrowableCUSDC.approve(user1, 100e6);

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Transfer(address(this), user1, 100e6);

        vm.prank(user1);
        borrowableCUSDC.transferFrom(address(this), user1, 100e6);

        assertEq(borrowableCUSDC.balanceOf(address(this)), balance - 100e6);
        assertEq(borrowableCUSDC.balanceOf(user1), user1Balance + 100e6);
    }

    function test_borrowableCTokenTransferFrom_success_withMaxApproval() public {
        deal(address(borrowableCUSDC), address(this), 100e6);

        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 user1Balance = borrowableCUSDC.balanceOf(user1);

        borrowableCUSDC.approve(user1, type(uint256).max);

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Transfer(address(this), user1, 100e6);

        vm.prank(user1);
        borrowableCUSDC.transferFrom(address(this), user1, 100e6);

        assertEq(borrowableCUSDC.balanceOf(address(this)), balance - 100e6);
        assertEq(borrowableCUSDC.balanceOf(user1), user1Balance + 100e6);
        assertEq(borrowableCUSDC.allowance(address(this), user1), type(uint256).max);
    }

    // If canTransfer incorrectly used msg.sender, this would revert.
    // This test is to ensure that checkTransfer is against the owner, not the caller.
    function test_transferFrom_success_whenSpenderDisabled() public {
        // Give owner shares and post most as collateral to test liquidity code path
        deal(address(borrowableCUSDC), address(this), 100e6);
        borrowableCUSDC.postCollateral(90e6);

        // skip hold period
        skip(20 minutes + 1);

        borrowableCUSDC.approve(user1, 100e6);

        uint256 ownerBal = borrowableCUSDC.balanceOf(address(this));
        uint256 recvBal = borrowableCUSDC.balanceOf(user2);
        uint256 ownerCollBefore = borrowableCUSDC.collateralPosted(address(this));

        // Disable transfers for owner (user1), true == disable
        vm.prank(user1);
        centralRegistry.setTransferableStatus(true);

        // Transfer amount exceeds idle shares to force collateral redemption 
        // triggering liquidity checks
        // idle = 10e6, so collateralRedeemed = 10e6
        uint256 transferAmount = 20e6;

        // would revert if msg.sender was used instead of owner
        vm.prank(user1);
        borrowableCUSDC.transferFrom(address(this), user2, transferAmount);

        assertEq(borrowableCUSDC.balanceOf(address(this)), ownerBal - transferAmount);
        assertEq(borrowableCUSDC.balanceOf(user2), recvBal + transferAmount);
        
        // Collateral reduced by (transferAmount - idleShares) = 10e6
        assertEq(borrowableCUSDC.collateralPosted(address(this)), ownerCollBefore - 10e6);
    }

    function test_transferFrom_fail_whenOwnerTransferDisabled() public {

        deal(address(borrowableCUSDC), address(this), 100e6);
        borrowableCUSDC.approve(user1, 100e6);

        // Disable transfers for owner (address(this))
        centralRegistry.setTransferableStatus(true);

        // will revert because owner's transfer is disabled
        vm.prank(user1);
        vm.expectRevert();
        borrowableCUSDC.transferFrom(address(this), user2, 100e6);
    }
}
