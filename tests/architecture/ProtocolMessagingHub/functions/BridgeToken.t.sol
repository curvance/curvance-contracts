// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { TestBaseProtocolMessagingHub } from "../TestBaseProtocolMessagingHub.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";

contract BridgeTokenTest is TestBaseProtocolMessagingHub {
    function setUp() public override {
        super.setUp();

        centralRegistry.addChainSupport(
            address(this),
            address(protocolMessagingHub),
            address(cve),
            _USDC_ADDRESS,
            42161,
            1,
            1,
            23
        );

        deal(address(cve), address(protocolMessagingHub), _ONE);
        deal(address(cve), _ONE);
        deal(address(veCVE), _ONE);
    }

    function test_bridgeToken_fail_whenMessagingHubIsPaused() public {
        protocolMessagingHub.flipMessagingHubStatus();

        vm.prank(address(cve));

        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__MessagingHubPaused
                .selector
        );
        protocolMessagingHub.bridgeToken(137, user1, _ONE, 0, 0, false);
    }

    function test_bridgeToken_fail_whenPayloadIsNot4_whenCallerIsNotCVE()
        public
    {
        vm.expectRevert(
            ProtocolMessagingHub.ProtocolMessagingHub__Unauthorized.selector
        );
        protocolMessagingHub.bridgeToken(137, user1, _ONE, 0, 0, false);
    }

    function test_bridgeToken_fail_whenPayloadIsNot4_whenMessagingHubHasNoEnoughCVE()
        public
    {
        vm.prank(address(cve));

        vm.expectRevert(ERC20.InsufficientBalance.selector);
        protocolMessagingHub.bridgeToken(137, user1, _ONE * 5, 0, 0, false);
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
        protocolMessagingHub.bridgeToken(138, user1, _ONE, 0, 0, false);
    }

    function test_bridgeToken_fail_whenPayloadIsNot4_whenRecipientIsZeroAddress()
        public
    {
        vm.prank(address(cve));

        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__InvalidRecipient
                .selector
        );
        protocolMessagingHub.bridgeToken(137, address(0), _ONE, 0, 0, false);
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
        protocolMessagingHub.flipMessagingHubStatus();

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
            137,
            true,
            0
        );

        assertEq(cve.bridgeFee(137, 0), messageFee);

        vm.prank(address(cve));

        protocolMessagingHub.bridgeToken{ value: messageFee }(
            137,
            user1,
            _ONE,
            0,
            0,
            false
        );

        assertEq(cve.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(cve.balanceOf(_TOKEN_BRIDGE), _ONE);
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
