// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ActionRegistry } from "contracts/libraries/ActionRegistry.sol";

contract SetDelegableTest is TestBaseMarket {
    event DelegableStatusChanged(
        address indexed user,
        bool delegable,
        uint256 delegationEnabledTimestamp
    );

    function test_setDelegable_fail_whenStatusIsNotFlipping() public {
        vm.expectRevert(
            ActionRegistry.ActionRegistry__InvalidParams.selector
        );
        centralRegistry.setDelegable(false);

        centralRegistry.setDelegable(true);

        vm.expectRevert(
            ActionRegistry.ActionRegistry__InvalidParams.selector
        );
        centralRegistry.setDelegable(true);
    }

    function test_setDelegable_fail_whenCooldownIsNotEnded() public {
        centralRegistry.setCooldown(10 days);

        centralRegistry.setDelegable(true);
        centralRegistry.setDelegable(false);
        centralRegistry.setDelegable(true);

        vm.expectRevert(
            ActionRegistry.ActionRegistry__InvalidParams.selector
        );
        centralRegistry.setDelegable(false);
    }

    function test_setDelegable_success() public {
        vm.startPrank(user1);

        assertFalse(centralRegistry.checkDelegationDisabled(user1));

        vm.expectEmit(true, true, true, true);
        emit DelegableStatusChanged(user1, true, 0);

        centralRegistry.setDelegable(true);

        assertTrue(centralRegistry.checkDelegationDisabled(user1));

        vm.expectEmit(true, true, true, true);
        emit DelegableStatusChanged(user1, false, block.timestamp);

        centralRegistry.setDelegable(false);

        assertFalse(centralRegistry.checkDelegationDisabled(user1));

        vm.stopPrank();
    }
}
