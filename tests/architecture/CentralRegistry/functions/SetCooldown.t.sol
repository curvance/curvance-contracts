// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

import { ActionRegistry } from "contracts/libraries/ActionRegistry.sol";
import { SECONDS_PER_YEAR } from "contracts/libraries/ConstantsLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract SetCooldownTest is TestBaseMarketIsolated {
    event CooldownSet(address indexed user, uint256 cooldown);

    function test_setCooldown_fail_whenCooldownExceedsMaximum() public {
        vm.expectRevert(
            ActionRegistry.ActionRegistry__InvalidParams.selector
        );
        centralRegistry.setCooldown(SECONDS_PER_YEAR + 1);
    }

    // Will pass because it's being set in the same block
    // It will enable the protection locks.
    function test_setCooldown_success_protectionActivatesWhenDecreasingInSameBlock() public {
        vm.startPrank(user1);

        assertFalse(centralRegistry.checkTransfersDisabled(user1));

        vm.expectEmit(true, true, true, true);
        emit CooldownSet(user1, 10 days);

        centralRegistry.setCooldown(10 days);

        assertFalse(centralRegistry.checkTransfersDisabled(user1));

        vm.expectEmit(true, true, true, true);
        emit CooldownSet(user1, 5 days);

        centralRegistry.setCooldown(5 days);

        // protection mechanism activates, transfers disabled for 10 days despite same block
        assertTrue(centralRegistry.checkTransfersDisabled(user1));

        skip(10 days);

        assertFalse(centralRegistry.checkTransfersDisabled(user1));

        vm.stopPrank();
    }

    // User tries to decrease cooldown when there's an active lock,
    // Triggering new later transfer and delegation lock
    function test_setCooldown_success_protectionAppliesWhenDecreasing() public {
        vm.startPrank(user1);

        vm.expectEmit(true, true, true, true);
        emit CooldownSet(user1, 10 days);
        centralRegistry.setCooldown(10 days);
        
        skip(1 hours);

        // Set cooldown to 0, triggering cooldown. 
        vm.expectEmit(true, true, true, true);
        emit CooldownSet(user1, 0);
        centralRegistry.setCooldown(0 minutes);

        vm.stopPrank();

        skip(9 days);

        // Transfer and delegation locks should still be active after 9 days.
        assertTrue(centralRegistry.checkTransfersDisabled(user1));
        assertTrue(centralRegistry.checkDelegationDisabled(user1));

        skip(1 days);

        // Locks should expire now that 10 days have passed.
        assertFalse(centralRegistry.checkTransfersDisabled(user1));
        assertFalse(centralRegistry.checkDelegationDisabled(user1));
    }

    // User tries to decrease cooldown when there's an active lock,
    // Triggering new later transfer and delegation lock
    function test_setCooldown_success_protectionAppliesWhenDecreasingCooldownMultipleTimes() public {
        vm.startPrank(user1);

        vm.expectEmit(true, true, true, true);
        emit CooldownSet(user1, 10 days);
        centralRegistry.setCooldown(10 days);
        
        skip(1 hours);

        // Set cooldown to 5 days, triggering cooldown.
        vm.expectEmit(true, true, true, true);
        emit CooldownSet(user1, 5 days);
        centralRegistry.setCooldown(5 days);

        // Try to set cooldown to 0, but cooldown is already active.
        vm.expectRevert(ActionRegistry.ActionRegistry__CooldownActive.selector);
        centralRegistry.setCooldown(0 minutes);

        vm.stopPrank();

        skip(9 days);

        // Transfer and delegation locks should still be active after 9 days.
        assertTrue(centralRegistry.checkTransfersDisabled(user1));
        assertTrue(centralRegistry.checkDelegationDisabled(user1));

        skip(1 days);

        // Locks should expire now that 10 days have passed.
        assertFalse(centralRegistry.checkTransfersDisabled(user1));
        assertFalse(centralRegistry.checkDelegationDisabled(user1));

    }

    // Increasing locks should always work
    function test_setCooldown_success_whenIncreasingCooldown() public {
        vm.startPrank(user1);

        vm.expectEmit(true, true, true, true);
        emit CooldownSet(user1, 10 days);
        centralRegistry.setCooldown(10 days);

        skip(1 days);

        vm.expectEmit(true, true, true, true);
        emit CooldownSet(user1, 20 days);
        centralRegistry.setCooldown(20 days);

    }

    // Edge case: manually enabling transfer lock in the same block
    function test_setCooldown_fail_whenTransferLockCooldownIsActive() public {
        vm.startPrank(user1);
        
        centralRegistry.setCooldown(15 days);
        
        // Use transfer lock to trigger cooldown.
        centralRegistry.setTransferableStatus(true);  // enable transfer lock
        centralRegistry.setTransferableStatus(false); // unlock triggers cooldown
        
        assertTrue(centralRegistry.checkTransfersDisabled(user1));
        
        // Try to decrease cooldown while transfer cooldown is active.
        vm.expectRevert(ActionRegistry.ActionRegistry__CooldownActive.selector);
        centralRegistry.setCooldown(5 days);
        
        vm.stopPrank();
    }

    // Edge case: manually enabling delegation lock in the same block
    function test_setCooldown_fail_whenDelegationLockCooldownIsActive() public {
        vm.startPrank(user1);
        
        centralRegistry.setCooldown(15 days);
        
        // use delegation lock to trigger cooldown
        centralRegistry.setDelegableStatus(true);  // enable delegation lock
        centralRegistry.setDelegableStatus(false); // unlock triggers cooldown
        
        assertTrue(centralRegistry.checkDelegationDisabled(user1));
        
        // try to decrease cooldown while delegation cooldown is active
        vm.expectRevert(ActionRegistry.ActionRegistry__CooldownActive.selector);
        centralRegistry.setCooldown(5 days);
        
        vm.stopPrank();
    }

    // Tests protection locks by setting and lowering the locks twice consecutively
    // enables protection locks on the second setCooldown, preventing the third
    // to execute.
    function test_setCooldown_fail_whenDecreasingMultipleTimesWithActiveProtection() public {
        vm.startPrank(user1);

        centralRegistry.setCooldown(10 days);

        skip(1 days);

        // trigger protection locks
        centralRegistry.setCooldown(5 days);

        // verify protection is active
        assertTrue(centralRegistry.checkTransfersDisabled(user1));
        assertTrue(centralRegistry.checkDelegationDisabled(user1));

        skip(1 days);

        // try to decrease cooldown while delegation cooldown is active
        vm.expectRevert(ActionRegistry.ActionRegistry__CooldownActive.selector);
        centralRegistry.setCooldown(2 days);
    }

    // Tests that cooldowns work with the maximum time allowed.
    function test_setCooldown_success_atMaximumRestraint() public {
        vm.expectEmit(true, true, true, true);
        emit CooldownSet(address(this), SECONDS_PER_YEAR);
        centralRegistry.setCooldown(SECONDS_PER_YEAR);
    }

    // Ensures the user cannot set the cooldown to zero while there are locks
    // in place.
    function test_setCooldown_fail_toZeroWithActiveLock() public {
        vm.startPrank(user1);
        
        centralRegistry.setCooldown(10 days);
        centralRegistry.setTransferableStatus(true);
        centralRegistry.setTransferableStatus(false);
        
        // try to set cooldown to 0 while lock is active
        vm.expectRevert(ActionRegistry.ActionRegistry__CooldownActive.selector);
        centralRegistry.setCooldown(0);
        
        vm.stopPrank();
    }

    function test_setCooldown_success_afterAllCooldownsExpire() public {
        vm.startPrank(user1);
        
        centralRegistry.setCooldown(10 days);
        
        // trigger both locks
        centralRegistry.setTransferableStatus(true);
        centralRegistry.setDelegableStatus(true);
        centralRegistry.setTransferableStatus(false);
        centralRegistry.setDelegableStatus(false);
        
        // wait for all cooldowns to expire
        skip(11 days);
        
        assertFalse(centralRegistry.checkTransfersDisabled(user1));
        assertFalse(centralRegistry.checkDelegationDisabled(user1));
        
        // now should be able set new cooldown
        vm.expectEmit(true, true, true, true);
        emit CooldownSet(user1, 5 days);
        centralRegistry.setCooldown(5 days);
        
        vm.stopPrank();
    }

}
