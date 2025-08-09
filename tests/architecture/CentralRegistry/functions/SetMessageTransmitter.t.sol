// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetMessageTransmitterTest is TestBaseMarketIsolated {
    event CoreContractUpdated(string indexed contractType, address newAddress);

    address public newMessageTransmitter = makeAddr("Message Transmitter");

    function test_setMessageTransmitter_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setMessageTransmitter(newMessageTransmitter);
    }

    function test_setMessageTransmitter_success() public {
        vm.expectEmit(true, true, true, true);
        emit CoreContractUpdated("Message Transmitter", newMessageTransmitter);

        centralRegistry.setMessageTransmitter(newMessageTransmitter);

        assertEq(
            address(centralRegistry.messageTransmitter()),
            newMessageTransmitter
        );
    }
}
