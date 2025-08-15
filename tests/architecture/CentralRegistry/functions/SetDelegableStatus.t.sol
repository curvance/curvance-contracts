// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ActionRegistry } from "contracts/libraries/ActionRegistry.sol";

contract setDelegableStatusTest is TestBaseMarketIsolated {
    event DelegableStatusChanged(
        address indexed user,
        bool delegable,
        uint256 delegationEnabledTimestamp
    );

    function test_setDelegableStatus_fail_whenStatusIsNotFlipping() public {
        vm.expectRevert(
            ActionRegistry.ActionRegistry__InvalidParams.selector
        );
        centralRegistry.setDelegableStatus(false);

        centralRegistry.setDelegableStatus(true);

        vm.expectRevert(
            ActionRegistry.ActionRegistry__InvalidParams.selector
        );
        centralRegistry.setDelegableStatus(true);
    }

    function test_setDelegableStatus_fail_whenCooldownIsNotEnded() public {
        centralRegistry.setCooldown(10 days);

        centralRegistry.setDelegableStatus(true);
        centralRegistry.setDelegableStatus(false);
        centralRegistry.setDelegableStatus(true);

        vm.expectRevert(
            ActionRegistry.ActionRegistry__CooldownActive.selector
        );
        centralRegistry.setDelegableStatus(false);
    }

    function test_setDelegableStatus_success() public {
        vm.startPrank(user1);

        assertFalse(centralRegistry.checkDelegationDisabled(user1));

        vm.expectEmit(true, true, true, true);
        emit DelegableStatusChanged(user1, true, 0);

        centralRegistry.setDelegableStatus(true);

        assertTrue(centralRegistry.checkDelegationDisabled(user1));

        vm.expectEmit(true, true, true, true);
        emit DelegableStatusChanged(user1, false, block.timestamp);

        centralRegistry.setDelegableStatus(false);

        assertFalse(centralRegistry.checkDelegationDisabled(user1));

        vm.stopPrank();
    }
}
