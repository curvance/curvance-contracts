// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseProtocolMessagingHub } from "../TestBaseProtocolMessagingHub.sol";
import { FeeTokenBridgingHub } from "contracts/architecture/FeeTokenBridgingHub.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract ProtocolMessagingHubDeploymentTest is TestBaseProtocolMessagingHub {
    function test_protocolMessagingHubDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            FeeTokenBridgingHub
                .FeeTokenBridgingHub__InvalidCentralRegistry
                .selector
        );
        new ProtocolMessagingHub(ICentralRegistry(address(0)), address(1));
    }

    function test_protocolMessagingHubDeployment_fail_whenWormholeAddressIsInvalid()
        public
    {
        vm.expectRevert(0x8ef9698f); // bytes4(keccak(EmptyWormholeAddress()))
        new ProtocolMessagingHub(ICentralRegistry(address(1)), address(0));
    }

    function test_protocolMessagingHubDeployment_success() public {
        protocolMessagingHub = new ProtocolMessagingHub(
            ICentralRegistry(address(centralRegistry)),
            address(1)
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
