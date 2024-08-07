// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetMessagingHubTest is TestBaseMarket {
    event CoreContractSet(string indexed contractType, address newAddress);

    address public newMessagingHub = makeAddr("Messaging Hub");

    function test_setMessagingHub_fail_whenUnauthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setMessagingHub(newMessagingHub);
    }

    function test_setMessagingHub_success() public {
        assertEq(centralRegistry.messagingHub(), address(messagingHub));

        vm.expectEmit(true, true, true, true);
        emit CoreContractSet("Messaging Hub", newMessagingHub);

        centralRegistry.setMessagingHub(newMessagingHub);

        assertEq(centralRegistry.messagingHub(), newMessagingHub);
    }
}
