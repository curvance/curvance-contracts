// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetDelegableTest is TestBaseMarket {
    event DelegableStatusSet(
        address indexed user,
        bool delegable,
        uint256 delegationEnabledTimestamp
    );

    function test_setDelegable_success() public {
        vm.startPrank(user1);

        assertFalse(centralRegistry.checkDelegationDisabled(user1));

        vm.expectEmit(true, true, true, true);
        emit DelegableStatusSet(user1, true, 0);

        centralRegistry.setDelegable(true);

        assertTrue(centralRegistry.checkDelegationDisabled(user1));

        vm.expectEmit(true, true, true, true);
        emit DelegableStatusSet(user1, false, block.timestamp);

        centralRegistry.setDelegable(false);

        assertFalse(centralRegistry.checkDelegationDisabled(user1));

        vm.stopPrank();
    }
}
