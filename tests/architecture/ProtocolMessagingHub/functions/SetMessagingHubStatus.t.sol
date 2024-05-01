// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseProtocolMessagingHub } from "../TestBaseProtocolMessagingHub.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";

contract SetMessagingHubStatusTest is TestBaseProtocolMessagingHub {
    function test_setMessagingHubStatus_fail_whenNewStatusIsZero() public {
        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__InvalidParameter
                .selector
        );
        protocolMessagingHub.setMessagingHubStatus(0);
    }

    function test_setMessagingHubStatus_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.startPrank(user1);

        vm.expectRevert(
            ProtocolMessagingHub.ProtocolMessagingHub__Unauthorized.selector
        );
        protocolMessagingHub.setMessagingHubStatus(2);

        vm.expectRevert(
            ProtocolMessagingHub.ProtocolMessagingHub__Unauthorized.selector
        );
        protocolMessagingHub.setMessagingHubStatus(3);

        vm.stopPrank();
    }

    function test_setMessagingHubStatus_success() public {
        assertEq(protocolMessagingHub.messagingStatus(), 1);

        protocolMessagingHub.setMessagingHubStatus(2);

        assertEq(protocolMessagingHub.messagingStatus(), 2);

        protocolMessagingHub.setMessagingHubStatus(3);

        assertEq(protocolMessagingHub.messagingStatus(), 3);
    }
}
