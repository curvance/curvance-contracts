// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MessagingHub } from "contracts/architecture/MessagingHub.sol";

import { ChainConfig } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseMessagingHub } from "../TestBaseMessagingHub.sol";

contract BridgeTokenTest is TestBaseMessagingHub {
    function setUp() public override {
        super.setUp();

        ChainConfig memory config;
        config.isSupported = true;
        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = address(messagingHub);
        config.votingHub = address(votingHub);
        config.cveAddress = address(cve);
        config.feeTokenAddress = _USDC_ADDRESS;
        config.crosschainRelayer = makeAddr("Wormhole Relayer");

        // Support chainId 42161.
        centralRegistry.addChain(42161, config);

        _prepareCVE(address(messagingHub), _ONE);
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
        centralRegistry.removeChain(
            42161,
            address(messagingHub),
            address(votingHub)
        );

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
        uint256 messageFee = messagingHub.quoteMessageFee(42161, 0);

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
        uint256 messageFee = messagingHub.quoteMessageFee(42161, 0);

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
        uint256 messageFee = messagingHub.quoteMessageFee(42161, 0);

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
