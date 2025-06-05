// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetCircleTokenMessengerTest is TestBaseMarketIsolated {
    event CircleTokenMessengerSet(address newAddress);

    address public newCircleTokenMessenger =
        makeAddr("Circle Token Messenger");

    function test_setCircleTokenMessenger_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setCircleTokenMessenger(newCircleTokenMessenger);
    }

    function test_setCircleTokenMessenger_success() public {
        assertEq(
            address(centralRegistry.circleTokenMessenger()),
            _CIRCLE_TOKEN_MESSENGER
        );

        vm.expectEmit(true, true, true, true);
        emit CircleTokenMessengerSet(newCircleTokenMessenger);

        centralRegistry.setCircleTokenMessenger(newCircleTokenMessenger);

        assertEq(
            address(centralRegistry.circleTokenMessenger()),
            newCircleTokenMessenger
        );
    }
}
