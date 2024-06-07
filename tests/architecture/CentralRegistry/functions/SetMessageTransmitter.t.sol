// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetMessageTransmitter is TestBaseMarket {
    event MessageTransmitterSet(address newAddress);

    address public newMessageTransmitter = makeAddr("Message Transmitter");

    function test_setMessageTransmitter_fail_whenUnauthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setMessageTransmitter(newMessageTransmitter);
    }

    function test_setMessageTransmitter_success() public {
        vm.expectEmit(true, true, true, true);
        emit MessageTransmitterSet(newMessageTransmitter);

        centralRegistry.setMessageTransmitter(newMessageTransmitter);

        assertEq(
            address(centralRegistry.circleMessageTransmitter()),
            newMessageTransmitter
        );
    }
}
