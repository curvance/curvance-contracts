// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetTokenMessengerTest is TestBaseMarketIsolated {
    event CoreContractUpdated(string indexed contractType, address newAddress);

    address public newCircleTokenMessenger =
        makeAddr("Circle Token Messenger");

    function test_setTokenMessenger_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setTokenMessager(newCircleTokenMessenger);
    }

    function test_setTokenMessenger_success() public {
        assertEq(
            address(centralRegistry.tokenMessager()),
            _CIRCLE_TOKEN_MESSENGER
        );

        vm.expectEmit(true, true, true, true);
        emit CoreContractUpdated("Token Messager", newCircleTokenMessenger);

        centralRegistry.setTokenMessager(newCircleTokenMessenger);

        assertEq(
            address(centralRegistry.tokenMessager()),
            newCircleTokenMessenger
        );
    }
}
