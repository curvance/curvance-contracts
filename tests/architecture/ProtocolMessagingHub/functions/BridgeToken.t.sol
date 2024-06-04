// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseProtocolMessagingHub } from "../TestBaseProtocolMessagingHub.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";

contract BridgeTokenTest is TestBaseProtocolMessagingHub {
    function setUp() public override {
        super.setUp();

        centralRegistry.addChainSupport(
            address(protocolMessagingHub),
            address(cve),
            _USDC_ADDRESS,
            42161,
            23,
            makeAddr("Wormhole Relayer"),
            3
        );

        deal(address(cve), address(protocolMessagingHub), _ONE);
        deal(address(cve), _ONE);
        deal(address(veCVE), _ONE);
    }

    function test_bridgeToken_fail_whenMessagingHubIsPaused() public {
        protocolMessagingHub.setMessagingHubStatus(2);

        vm.prank(address(cve));

        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__MessagingHubPaused
                .selector
        );
        protocolMessagingHub.bridgeToken(42161, user1, _ONE, 0, 0, false);
    }

    function test_bridgeToken_fail_whenPayloadIsNot4_whenCallerIsNotCVE()
        public
    {
        vm.expectRevert(
            ProtocolMessagingHub.ProtocolMessagingHub__Unauthorized.selector
        );
        protocolMessagingHub.bridgeToken(42161, user1, _ONE, 0, 0, false);
    }

    function test_bridgeToken_fail_whenPayloadIsNot4_whenDestinationChainIsNotRegistered()
        public
    {
        vm.prank(address(cve));

        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__InvalidParameter
                .selector
        );
        protocolMessagingHub.bridgeToken(42162, user1, _ONE, 0, 0, false);
    }

    function test_bridgeToken_fail_whenPayloadIsNot4_whenRecipientIsZeroAddress()
        public
    {
        vm.prank(address(cve));

        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__InvalidParameter
                .selector
        );
        protocolMessagingHub.bridgeToken(42161, address(0), _ONE, 0, 0, false);
    }

    function test_bridgeToken_fail_whenPayloadIs4_whenCallerIsNotVeCVE()
        public
    {
        vm.expectRevert(
            ProtocolMessagingHub.ProtocolMessagingHub__Unauthorized.selector
        );
        protocolMessagingHub.bridgeToken(42161, user1, _ONE, 0, 4, true);
    }

    function test_bridgeToken_fail_whenPayloadIs4_whenMessagingHubIsPaused()
        public
    {
        protocolMessagingHub.setMessagingHubStatus(2);

        vm.prank(address(veCVE));

        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__MessagingHubPaused
                .selector
        );
        protocolMessagingHub.bridgeToken(42161, user1, _ONE, 0, 4, true);
    }

    function test_bridgeToken_fail_whenPayloadIs4_whenDestinationChainIsNotRegistered()
        public
    {
        vm.prank(address(veCVE));

        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__InvalidParameter
                .selector
        );
        protocolMessagingHub.bridgeToken(138, user1, _ONE, 0, 4, true);
    }

    function test_bridgeToken_fail_whenPayloadIs4_whenNativeTokenIsNotEnoughToCoverFee()
        public
    {
        uint256 messageFee = protocolMessagingHub.quoteMessageFee(
            42161,
            false,
            0
        );

        vm.prank(address(veCVE));

        vm.expectRevert();
        protocolMessagingHub.bridgeToken{ value: messageFee - 1 }(
            42161,
            user1,
            _ONE,
            0,
            4,
            true
        );
    }

    function test_bridgeToken_success_whenBridgeCVE() public {
        uint256 messageFee = protocolMessagingHub.quoteMessageFee(
            42161,
            true,
            0
        );

        assertEq(cve.bridgeFee(42161, 0), messageFee);

        vm.prank(address(cve));

        protocolMessagingHub.bridgeToken{ value: messageFee }(
            42161,
            user1,
            _ONE,
            0,
            0,
            false
        );
    }

    function test_bridgeToken_success_whenBridgeVeCVELock() public {
        uint256 messageFee = protocolMessagingHub.quoteMessageFee(
            42161,
            false,
            0
        );

        vm.prank(address(veCVE));

        protocolMessagingHub.bridgeToken{ value: messageFee }(
            42161,
            user1,
            _ONE,
            0,
            4,
            true
        );
    }
}
