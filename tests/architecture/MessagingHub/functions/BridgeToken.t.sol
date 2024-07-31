// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMessagingHub } from "../TestBaseMessagingHub.sol";
import { MessagingHub } from "contracts/architecture/MessagingHub.sol";

contract BridgeTokenTest is TestBaseMessagingHub {
    function setUp() public override {
        super.setUp();

        centralRegistry.addChainSupport(
            address(messagingHub),
            address(cve),
            _USDC_ADDRESS,
            42161,
            23,
            makeAddr("Wormhole Relayer"),
            3
        );

        deal(address(cve), address(messagingHub), _ONE);
        deal(address(cve), _ONE);
        deal(address(veCVE), _ONE);
    }

    function test_bridgeToken_fail_whenMessagingHubIsPaused() public {
        messagingHub.setMessagingHubStatus(2);

        vm.prank(address(cve));

        vm.expectRevert(
            MessagingHub.MessagingHub__MessagingHubPaused.selector
        );
        messagingHub.bridgeToken(42161, user1, _ONE, 0, 0, false);
    }

    function test_bridgeToken_fail_whenWormholeChainIdIsInvalid() public {
        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        messagingHub.bridgeToken(42162, user1, _ONE, 0, 0, false);
    }

    function test_bridgeToken_fail_whenDestinationChainIsNotSupported()
        public
    {
        centralRegistry.removeChainSupport(address(messagingHub), 42161);

        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        messagingHub.bridgeToken(42161, user1, _ONE, 0, 0, false);
    }

    function test_bridgeToken_fail_whenPayloadIsNot4_whenCallerIsNotCVE()
        public
    {
        vm.expectRevert(MessagingHub.MessagingHub__Unauthorized.selector);
        messagingHub.bridgeToken(42161, user1, _ONE, 0, 0, false);
    }

    function test_bridgeToken_fail_whenPayloadIsNot4_whenRecipientIsZeroAddress()
        public
    {
        vm.prank(address(cve));

        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        messagingHub.bridgeToken(42161, address(0), _ONE, 0, 0, false);
    }

    function test_bridgeToken_fail_whenPayloadIs4_whenCallerIsNotVeCVE()
        public
    {
        vm.expectRevert(MessagingHub.MessagingHub__Unauthorized.selector);
        messagingHub.bridgeToken(42161, user1, _ONE, 0, 4, true);
    }

    function test_bridgeToken_fail_whenPayloadIs4_whenMessagingHubIsPaused()
        public
    {
        messagingHub.setMessagingHubStatus(2);

        vm.prank(address(veCVE));

        vm.expectRevert(
            MessagingHub.MessagingHub__MessagingHubPaused.selector
        );
        messagingHub.bridgeToken(42161, user1, _ONE, 0, 4, true);
    }

    function test_bridgeToken_fail_whenPayloadIs4_whenNativeTokenIsNotEnoughToCoverFee()
        public
    {
        uint256 messageFee = messagingHub.quoteMessageFee(42161, false, 0);

        vm.prank(address(veCVE));

        vm.expectRevert();
        messagingHub.bridgeToken{ value: messageFee - 1 }(
            42161,
            user1,
            _ONE,
            0,
            4,
            true
        );
    }

    function test_bridgeToken_success_whenBridgeCVE() public {
        uint256 messageFee = messagingHub.quoteMessageFee(42161, true, 0);

        assertEq(cve.bridgeFee(42161, 0), messageFee);

        vm.prank(address(cve));

        messagingHub.bridgeToken{ value: messageFee }(
            42161,
            user1,
            _ONE,
            0,
            0,
            false
        );
    }

    function test_bridgeToken_success_whenBridgeVeCVELock() public {
        uint256 messageFee = messagingHub.quoteMessageFee(42161, false, 0);

        vm.prank(address(veCVE));

        messagingHub.bridgeToken{ value: messageFee }(
            42161,
            user1,
            _ONE,
            0,
            4,
            true
        );
    }
}
