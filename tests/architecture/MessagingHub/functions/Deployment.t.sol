// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMessagingHub } from "../TestBaseMessagingHub.sol";
import { MessagingHub } from "contracts/architecture/MessagingHub.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract InvalidCentralRegistry {
    function crosschainCore() external pure returns (address) {
        return address(1);
    }
}

contract MessagingHubDeploymentTest is TestBaseMessagingHub {
    function test_messagingHubDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        address invalidCentralRegistry = address(new InvalidCentralRegistry());

        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        new MessagingHub(ICentralRegistry(invalidCentralRegistry));
    }

    function test_messagingHubDeployment_success() public {
        messagingHub = new MessagingHub(
            ICentralRegistry(address(centralRegistry))
        );

        assertEq(
            address(messagingHub.centralRegistry()),
            address(centralRegistry)
        );
    }
}
