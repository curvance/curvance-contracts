// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ActionRegistry } from "contracts/libraries/ActionRegistry.sol";

contract SetTransferLockStatusTest is TestBaseMarket {
    event LockStatusChanged(
        address indexed user,
        bool locked,
        uint256 timestamp
    );

    function test_setTransferLockStatus_fail_whenStatusIsNotFlipping() public {
        vm.expectRevert(
            ActionRegistry.ActionRegistry__InvalidParams.selector
        );
        centralRegistry.setTransferLockStatus(false);

        centralRegistry.setTransferLockStatus(true);

        vm.expectRevert(
            ActionRegistry.ActionRegistry__InvalidParams.selector
        );
        centralRegistry.setTransferLockStatus(true);
    }

    function test_setTransferLockStatus_fail_whenCooldownIsNotEnded() public {
        centralRegistry.setTransferLockStatus(true);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.expectRevert(
            ActionRegistry.ActionRegistry__InvalidParams.selector
        );
        centralRegistry.setTransferLockStatus(false);
    }

    function test_setTransferLockStatus_success() public {
        vm.startPrank(user1);

        assertFalse(centralRegistry.checkTransfersDisabled(user1));

        vm.expectEmit(true, true, true, true);
        emit LockStatusChanged(user1, true, 0);

        centralRegistry.setTransferLockStatus(true);

        assertTrue(centralRegistry.checkTransfersDisabled(user1));

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        skip(10 days);

        vm.expectEmit(true, true, true, true);
        emit LockStatusChanged(user1, false, block.timestamp + 5 days);

        centralRegistry.setTransferLockStatus(false);

        assertTrue(centralRegistry.checkTransfersDisabled(user1));

        skip(5 days);

        assertFalse(centralRegistry.checkTransfersDisabled(user1));

        vm.stopPrank();
    }
}
