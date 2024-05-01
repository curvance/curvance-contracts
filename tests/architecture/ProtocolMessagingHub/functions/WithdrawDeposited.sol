// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseProtocolMessagingHub } from "../TestBaseProtocolMessagingHub.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";

contract WithdrawDepositedTest is TestBaseProtocolMessagingHub {
    function setUp() public override {
        super.setUp();

        deal(address(protocolMessagingHub), _ONE);
        deal(_USDC_ADDRESS, address(protocolMessagingHub), _ONE);
    }

    function test_withdrawDeposited_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.expectRevert(ProtocolMessagingHub.ProtocolMessagingHub__Unauthorized.selector);

        vm.prank(address(1));
        protocolMessagingHub.withdrawDeposited();
    }

    function test_withdrawDeposited_success() public {
        uint256 balance = centralRegistry.daoAddress().balance;
        protocolMessagingHub.withdrawDeposited();

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(address(protocolMessagingHub).balance, 0);

        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), _ONE);
        assertEq(centralRegistry.daoAddress().balance, balance + _ONE);
    }
}
