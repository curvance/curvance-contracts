// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMessagingHub } from "../TestBaseMessagingHub.sol";
import { MessagingHub } from "contracts/architecture/MessagingHub.sol";

contract SetMessagingHubStatusTest is TestBaseMessagingHub {
    function test_setMessagingHubStatus_fail_whenNewStatusIsZero() public {
        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        messagingHub.setMessagingHubStatus(0);
    }

    function test_setMessagingHubStatus_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.startPrank(user1);

        vm.expectRevert(MessagingHub.MessagingHub__Unauthorized.selector);
        messagingHub.setMessagingHubStatus(2);

        vm.expectRevert(MessagingHub.MessagingHub__Unauthorized.selector);
        messagingHub.setMessagingHubStatus(3);

        vm.stopPrank();
    }

    function test_setMessagingHubStatus_success() public {
        assertEq(messagingHub.messagingStatus(), 1);

        messagingHub.setMessagingHubStatus(2);

        assertEq(messagingHub.messagingStatus(), 2);

        messagingHub.setMessagingHubStatus(3);

        assertEq(messagingHub.messagingStatus(), 3);
    }
}
