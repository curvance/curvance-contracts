// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseMessagingHub } from "../TestBaseMessagingHub.sol";
import { MessagingHub } from "contracts/architecture/MessagingHub.sol";

contract WithdrawDepositedTest is TestBaseMessagingHub {
    receive() external payable {}

    function setUp() public override {
        super.setUp();

        deal(address(messagingHub), _ONE);
        _prepareUSDC(address(messagingHub), _ONE);
    }

    function test_withdrawDeposited_fail_whenCallerIsNotAuthorized() public {
        vm.expectRevert(MessagingHub.MessagingHub__Unauthorized.selector);

        vm.prank(address(1));
        messagingHub.withdrawDeposited();
    }

    function test_withdrawDeposited_success() public {
        uint256 balance = centralRegistry.daoAddress().balance;
        messagingHub.withdrawDeposited();

        assertEq(usdc.balanceOf(address(messagingHub)), 0);
        assertEq(address(messagingHub).balance, 0);

        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), _ONE);
        assertEq(centralRegistry.daoAddress().balance, balance + _ONE);
    }
}
