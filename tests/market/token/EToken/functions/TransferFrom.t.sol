// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract ETokenTransferFromTest is TestBaseEToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_eTokenTransferFrom_fail_whenSenderAndReceiverAreSame()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__TransferError.selector);
        eUSDC.transferFrom(address(this), address(this), 100e6);
    }

    function test_eTokenTransferFrom_fail_whenTransferZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        eUSDC.transferFrom(address(this), user1, 0);
    }

    function test_eTokenTransferFrom_fail_whenAllowanceIsInvalid() public {
        vm.expectRevert();
        eUSDC.transferFrom(user1, address(this), 100e6);
    }

    function test_transfer_fail_whenTransferIsNotAllowed() public {
        marketManagerIsolated.setTransferPaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        eUSDC.transferFrom(address(this), user1, 100e6);
    }

    function test_eTokenTransferFrom_success() public {
        deal(address(eUSDC), address(this), 100e6);

        uint256 balance = eUSDC.balanceOf(address(this));
        uint256 user1Balance = eUSDC.balanceOf(user1);

        vm.expectEmit(true, true, true, true, address(eUSDC));
        emit Transfer(address(this), user1, 100e6);

        eUSDC.transferFrom(address(this), user1, 100e6);

        assertEq(eUSDC.balanceOf(address(this)), balance - 100e6);
        assertEq(eUSDC.balanceOf(user1), user1Balance + 100e6);
    }
}
