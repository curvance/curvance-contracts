// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract ETokenTransferTest is TestBaseEToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_eTokenTransfer_fail_whenSenderAndReceiverAreSame() public {
        vm.expectRevert(BaseCToken.BaseCToken__TransferError.selector);
        borrowableCUSDC.transfer(address(this), 100e6);
    }

    function test_eTokenTransfer_fail_whenTransferZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        borrowableCUSDC.transfer(user1, 0);
    }

    function test_eTokenTransfer_fail_whenTransferIsNotAllowed() public {
        deal(address(borrowableCUSDC), address(this), 100e6);
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCUSDC.transfer(user1, 10e6);
    }

    function test_eTokenTransfer_success() public {
        deal(address(borrowableCUSDC), address(this), 100e6);

        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 user1Balance = borrowableCUSDC.balanceOf(user1);

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Transfer(address(this), user1, 100e6);

        borrowableCUSDC.transfer(user1, 100e6);

        assertEq(borrowableCUSDC.balanceOf(address(this)), balance - 100e6);
        assertEq(borrowableCUSDC.balanceOf(user1), user1Balance + 100e6);
    }
}
