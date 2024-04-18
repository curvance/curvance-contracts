// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseProtocolMessagingHub } from "../TestBaseProtocolMessagingHub.sol";
import { FeeTokenBridgingHub } from "contracts/architecture/FeeTokenBridgingHub.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract InvalidCentralRegistry {
    function wormholeCore() external view returns (address) {}
}

contract ProtocolMessagingHubDeploymentTest is TestBaseProtocolMessagingHub {
    function test_protocolMessagingHubDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        address invalidCentralRegistry = address(new InvalidCentralRegistry());

        vm.expectRevert(
            FeeTokenBridgingHub
                .FeeTokenBridgingHub__InvalidCentralRegistry
                .selector
        );
        new ProtocolMessagingHub(ICentralRegistry(invalidCentralRegistry));
    }

    function test_protocolMessagingHubDeployment_success() public {
        protocolMessagingHub = new ProtocolMessagingHub(
            ICentralRegistry(address(centralRegistry))
        );

        assertEq(
            address(protocolMessagingHub.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(
            address(protocolMessagingHub.cve()),
            address(centralRegistry.cve())
        );
        assertEq(protocolMessagingHub.feeToken(), _USDC_ADDRESS);
    }
}
