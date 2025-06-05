// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetTokenBridgeTest is TestBaseMarketIsolated {
    event TokenBridgeSet(address newAddress);

    address public newTokenBridge = makeAddr("Token Bridge");

    function test_setTokenBridge_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setTokenBridge(newTokenBridge);
    }

    function test_setTokenBridge_success() public {
        assertEq(address(centralRegistry.tokenBridge()), _TOKEN_BRIDGE);

        vm.expectEmit(true, true, true, true);
        emit TokenBridgeSet(newTokenBridge);

        centralRegistry.setTokenBridge(newTokenBridge);

        assertEq(address(centralRegistry.tokenBridge()), newTokenBridge);
    }
}
