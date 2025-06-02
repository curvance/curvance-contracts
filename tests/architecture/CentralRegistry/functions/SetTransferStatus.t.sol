// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ActionRegistry } from "contracts/libraries/ActionRegistry.sol";

contract setTransferStatusTest is TestBaseMarket {
    event LockStatusChanged(
        address indexed user,
        bool locked,
        uint256 timestamp
    );

    function test_setTransferStatus_fail_whenStatusIsNotFlipping() public {
        vm.expectRevert(
            ActionRegistry.ActionRegistry__InvalidParams.selector
        );
        centralRegistry.setTransferStatus(false);

        centralRegistry.setTransferStatus(true);

        vm.expectRevert(
            ActionRegistry.ActionRegistry__InvalidParams.selector
        );
        centralRegistry.setTransferStatus(true);
    }

    function test_setTransferStatus_fail_whenCooldownIsNotEnded() public {
        centralRegistry.setTransferStatus(true);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.expectRevert(
            ActionRegistry.ActionRegistry__CooldownActive.selector
        );
        centralRegistry.setTransferStatus(false);
    }

    function test_setTransferStatus_success() public {
        vm.startPrank(user1);

        assertFalse(centralRegistry.checkTransfersDisabled(user1));

        vm.expectEmit(true, true, true, true);
        emit LockStatusChanged(user1, true, 0);

        centralRegistry.setTransferStatus(true);

        assertTrue(centralRegistry.checkTransfersDisabled(user1));

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        skip(10 days);

        vm.expectEmit(true, true, true, true);
        emit LockStatusChanged(user1, false, block.timestamp + 5 days);

        centralRegistry.setTransferStatus(false);

        assertTrue(centralRegistry.checkTransfersDisabled(user1));

        skip(5 days);

        assertFalse(centralRegistry.checkTransfersDisabled(user1));

        vm.stopPrank();
    }
}
