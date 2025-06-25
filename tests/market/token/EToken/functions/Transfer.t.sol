// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract ETokenTransferTest is TestBaseEToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_eTokenTransfer_fail_whenSenderAndReceiverAreSame() public {
        vm.expectRevert(BorrowableCToken.BorrowableCToken__TransferError.selector);
        eUSDC.transfer(address(this), 100e6);
    }

    function test_eTokenTransfer_fail_whenTransferZeroAmount() public {
        vm.expectRevert(BorrowableCToken.BorrowableCToken__EmptyAction.selector);
        eUSDC.transfer(user1, 0);
    }

    function test_eTokenTransfer_fail_whenTransferIsNotAllowed() public {
        deal(address(eUSDC), address(this), 100e6);
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        eUSDC.transfer(user1, 10e6);
    }

    function test_eTokenTransfer_success() public {
        deal(address(eUSDC), address(this), 100e6);

        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 user1Balance = eUSDC.balanceOf(user1);

        vm.expectEmit(true, true, true, true, address(eUSDC));
        emit Transfer(address(this), user1, 100e6);

        eUSDC.transfer(user1, 100e6);

        assertEq(eUSDC.balanceOf(address(this)), balance - 100e6);
        assertEq(eUSDC.balanceOf(user1), user1Balance + 100e6);
    }
}
