// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetMessagingHubTest is TestBaseMarketIsolated {
    event CoreContractUpdated(string indexed contractType, address newAddress);

    address public newMessagingHub = makeAddr("Messaging Hub");

    function test_setMessagingHub_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setMessagingHub(newMessagingHub);
    }

    function test_setMessagingHub_success() public {
        assertEq(centralRegistry.messagingHub(), address(messagingHub));

        vm.expectEmit(true, true, true, true);
        emit CoreContractUpdated("Messaging Hub", newMessagingHub);

        centralRegistry.setMessagingHub(newMessagingHub);

        assertEq(centralRegistry.messagingHub(), newMessagingHub);
    }
}
