// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseProtocolMessagingHub } from "../TestBaseProtocolMessagingHub.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";

contract WithdrawNativeTest is TestBaseProtocolMessagingHub {
    function setUp() public override {
        super.setUp();

        deal(address(protocolMessagingHub), _ONE);
    }

    function test_withdrawNative_fail_whenCallerIsNotAuthorized() public {
        vm.expectRevert(
            ProtocolMessagingHub.ProtocolMessagingHub__Unauthorized.selector
        );

        vm.prank(address(1));
        protocolMessagingHub.withdrawNative(_ONE);
    }

    function test_withdrawNative_fail_whenAmountExceedsBalance() public {
        vm.expectRevert(
            ProtocolMessagingHub.ProtocolMessagingHub__InvalidBalance.selector
        );

        protocolMessagingHub.withdrawNative(_ONE + 1);
    }

    function test_withdrawNative_success() public {
        uint256 balance = centralRegistry.daoAddress().balance;

        protocolMessagingHub.withdrawNative(_ONE);

        assertEq(address(protocolMessagingHub).balance, 0);
        assertEq(centralRegistry.daoAddress().balance, balance + _ONE);
    }
}
