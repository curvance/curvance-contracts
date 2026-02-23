// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MessagingHub } from "contracts/architecture/MessagingHub.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseMessagingHub } from "../TestBaseMessagingHub.sol";

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

        vm.expectRevert(
            CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry
                .selector
        );
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
