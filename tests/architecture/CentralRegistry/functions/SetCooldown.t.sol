// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { LockableRegistry } from "contracts/libraries/LockableRegistry.sol";

contract SetCooldownTest is TestBaseMarket {
    event CooldownSet(address indexed user, uint256 cooldown);

    function test_setCooldown_fail_whenCooldownExceedsMaximum() public {
        uint256 maximumCooldown = centralRegistry.COOLDOWN_MAXIMUM();

        vm.expectRevert(
            LockableRegistry.LockableRegistry__UnsafeCooldown.selector
        );
        centralRegistry.setCooldown(maximumCooldown + 1);
    }

    function test_setCooldown_success() public {
        vm.startPrank(user1);

        assertFalse(centralRegistry.checkTransfersDisabled(user1));

        vm.expectEmit(true, true, true, true);
        emit CooldownSet(user1, 10 days);

        centralRegistry.setCooldown(10 days);

        assertFalse(centralRegistry.checkTransfersDisabled(user1));

        vm.expectEmit(true, true, true, true);
        emit CooldownSet(user1, 5 days);

        centralRegistry.setCooldown(5 days);

        assertTrue(centralRegistry.checkTransfersDisabled(user1));

        skip(10 days);

        assertFalse(centralRegistry.checkTransfersDisabled(user1));

        vm.stopPrank();
    }
}
