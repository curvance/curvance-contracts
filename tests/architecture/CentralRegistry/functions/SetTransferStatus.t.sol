// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ActionRegistry } from "contracts/libraries/ActionRegistry.sol";

contract setTransferableStatusTest is TestBaseMarketIsolated {
    event TransferableStatusChanged(
        address indexed user,
        bool locked,
        uint256 timestamp
    );

    function test_setTransferableStatus_fail_whenStatusIsNotFlipping() public {
        vm.expectRevert(
            ActionRegistry.ActionRegistry__InvalidParams.selector
        );
        centralRegistry.setTransferableStatus(false);

        centralRegistry.setTransferableStatus(true);

        vm.expectRevert(
            ActionRegistry.ActionRegistry__InvalidParams.selector
        );
        centralRegistry.setTransferableStatus(true);
    }

    function test_setTransferableStatus_fail_whenCooldownIsNotEnded() public {
        centralRegistry.setTransferableStatus(true);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.expectRevert(
            ActionRegistry.ActionRegistry__CooldownActive.selector
        );
        centralRegistry.setTransferableStatus(false);
    }

    function test_setTransferableStatus_success() public {
        vm.startPrank(user1);

        assertFalse(centralRegistry.checkTransfersDisabled(user1));

        vm.expectEmit(true, true, true, true);
        emit TransferableStatusChanged(user1, true, 0);

        centralRegistry.setTransferableStatus(true);

        assertTrue(centralRegistry.checkTransfersDisabled(user1));

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        skip(10 days);

        vm.expectEmit(true, true, true, true);
        emit TransferableStatusChanged(user1, false, block.timestamp + 5 days);

        centralRegistry.setTransferableStatus(false);

        assertTrue(centralRegistry.checkTransfersDisabled(user1));

        skip(5 days);

        assertFalse(centralRegistry.checkTransfersDisabled(user1));

        vm.stopPrank();
    }
}
