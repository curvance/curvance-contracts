// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMessagingHub } from "../TestBaseMessagingHub.sol";
import { MessagingHub } from "contracts/architecture/MessagingHub.sol";
import { MockMessageTransmitter } from "contracts/mocks/MockMessageTransmitter.sol";
import { EmissionData } from "contracts/interfaces/IMessagingHub.sol";
import { stdStorage, StdStorage } from "forge-std/Test.sol";

contract MessagingHubReceiveWormholeMessagesTest is TestBaseMessagingHub {
    using stdStorage for StdStorage;

    address public srcMessagingHub;
    bytes[] public additionalMessages;

    function setUp() public override {
        super.setUp();

        srcMessagingHub = makeAddr("SrcMessagingHub");
        additionalMessages.push(abi.encode("1", "1"));

        centralRegistry.addChainSupport(
            srcMessagingHub,
            srcVotingHub,
            address(cve),
            _USDC_ADDRESS,
            42161,
            23,
            makeAddr("Wormhole Relayer"),
            3
        );

        MockMessageTransmitter(
            address(centralRegistry.circleMessageTransmitter())
        ).enableForceTransfer(_USDC_ADDRESS, address(messagingHub), 100e6);
    }

    function test_receiveWormholeMessages_fail_whenCallerIsNotWormholeRelayer()
        public
    {
        vm.expectRevert(MessagingHub.MessagingHub__Unauthorized.selector);
        messagingHub.receiveWormholeMessages(
            abi.encode(1, _addressToBytes32(_USDC_ADDRESS), 100e6),
            additionalMessages,
            _addressToBytes32(srcMessagingHub),
            23,
            bytes32("1")
        );
    }

    function test_receiveWormholeMessages_fail_whenNotHaveOneCCTPTransfer()
        public
    {
        additionalMessages.push(abi.encode("1", "1"));

        vm.startPrank(_WORMHOLE_RELAYER);

        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        messagingHub.receiveWormholeMessages(
            abi.encode(1, _addressToBytes32(_USDC_ADDRESS), 100e6),
            additionalMessages,
            _addressToBytes32(srcMessagingHub),
            23,
            bytes32("1")
        );

        uint256 nextEpoch = rewardManager.nextEpochToDeliver();

        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        messagingHub.receiveWormholeMessages(
            abi.encode(3, nextEpoch, _ONE),
            additionalMessages,
            _addressToBytes32(srcMessagingHub),
            23,
            bytes32("1")
        );

        vm.stopPrank();
    }

    function test_receiveWormholeMessages_fail_whenMessagingHubIsPaused()
        public
    {
        messagingHub.setMessagingHubStatus(3);

        vm.prank(_WORMHOLE_RELAYER);

        vm.expectRevert(
            MessagingHub.MessagingHub__MessagingHubPaused.selector
        );
        messagingHub.receiveWormholeMessages(
            abi.encode(1, _addressToBytes32(_USDC_ADDRESS), 100e6),
            additionalMessages,
            _addressToBytes32(srcMessagingHub),
            23,
            bytes32("1")
        );
    }

    function test_receiveWormholeMessages_fail_whenMessageIsAlreadyDelivered()
        public
    {
        deal(_USDC_ADDRESS, address(messagingHub), 100e6);

        vm.startPrank(_WORMHOLE_RELAYER);

        messagingHub.receiveWormholeMessages(
            abi.encode(1, _addressToBytes32(_USDC_ADDRESS), 100e6),
            additionalMessages,
            _addressToBytes32(srcMessagingHub),
            23,
            bytes32("1")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                MessagingHub
                    .MessagingHub__MessageHashIsAlreadyDelivered
                    .selector,
                bytes32("1")
            )
        );
        messagingHub.receiveWormholeMessages(
            abi.encode(1, _addressToBytes32(_USDC_ADDRESS), 100e6),
            additionalMessages,
            _addressToBytes32(srcMessagingHub),
            23,
            bytes32("1")
        );

        vm.stopPrank();
    }

    function test_receiveWormholeMessages_success_whenSourceAddressIsNotMessagingHub()
        public
    {
        deal(_USDC_ADDRESS, address(messagingHub), 100e6);

        vm.prank(_WORMHOLE_RELAYER);
        messagingHub.receiveWormholeMessages(
            abi.encode(1, _addressToBytes32(_USDC_ADDRESS), 100e6),
            additionalMessages,
            bytes32(0),
            23,
            bytes32("1")
        );

        assertEq(usdc.balanceOf(address(messagingHub)), 100e6);
        assertEq(usdc.balanceOf(address(rewardManager)), 0);
    }

    function test_receiveWormholeMessages_success_whenOperatorIsNotAuthorized()
        public
    {
        deal(_USDC_ADDRESS, address(messagingHub), 100e6);

        vm.prank(_WORMHOLE_RELAYER);
        messagingHub.receiveWormholeMessages(
            abi.encode(1, _addressToBytes32(_USDC_ADDRESS), 100e6),
            additionalMessages,
            _addressToBytes32(address(1)),
            23,
            bytes32("1")
        );

        assertEq(usdc.balanceOf(address(messagingHub)), 100e6);
        assertEq(usdc.balanceOf(address(rewardManager)), 0);
    }

    function test_receiveWormholeMessages_success_whenPayloadTypeIs1() public {
        assertEq(usdc.balanceOf(address(messagingHub)), 0);

        vm.prank(_WORMHOLE_RELAYER);
        messagingHub.receiveWormholeMessages(
            abi.encode(1, _addressToBytes32(_USDC_ADDRESS), 100e6),
            additionalMessages,
            _addressToBytes32(srcMessagingHub),
            23,
            bytes32("1")
        );

        assertEq(usdc.balanceOf(address(messagingHub)), 100e6);
        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), 0);

        rewardManager.notifyShutdown();

        vm.prank(_WORMHOLE_RELAYER);
        messagingHub.receiveWormholeMessages(
            abi.encode(1, _addressToBytes32(_USDC_ADDRESS), 100e6),
            additionalMessages,
            _addressToBytes32(srcMessagingHub),
            23,
            bytes32("2")
        );

        assertEq(usdc.balanceOf(address(messagingHub)), 100e6);
        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), 100e6);
    }

    function test_receiveWormholeMessages_success_whenPayloadTypeIs2() public {
        
        vm.warp(veCVE.nextEpochStartTime() + 100);

        uint256 epoch = gaugeManager.currentEpoch();

        EmissionData memory emissionData;

        emissionData.tokens = new address[](1);
        emissionData.emissions = new uint256[](1);

        emissionData.emissionTotal = _ONE;
        emissionData.tokens[0] = _USDC_ADDRESS;
        emissionData.emissions[0] = _ONE;

        vm.prank(_WORMHOLE_RELAYER);
        messagingHub.receiveWormholeMessages(
            abi.encode(2, epoch, emissionData),
            additionalMessages,
            _addressToBytes32(srcMessagingHub),
            23,
            bytes32("1")
        );

        (uint256 totalWeights, uint256 poolWeight) = gaugeManager.gaugeWeight(
            epoch,
            _USDC_ADDRESS
        );

        assertEq(totalWeights, _ONE);
        assertEq(poolWeight, _ONE);
        assertEq(cve.balanceOf(address(gaugeManager)), _ONE);
    }

    function test_receiveWormholeMessages_success_whenPayloadTypeIs3() public {
        uint256 nextEpoch = rewardManager.nextEpochToDeliver();

        assertEq(rewardManager.epochRewardsPerPoint(nextEpoch), 0);

        uint256 rewardManagerBalance = usdc.balanceOf(address(rewardManager));
        uint256 daoBalance = usdc.balanceOf(centralRegistry.daoAddress());

        vm.prank(_WORMHOLE_RELAYER);
        messagingHub.receiveWormholeMessages(
            abi.encode(3, nextEpoch, _ONE),
            additionalMessages,
            _addressToBytes32(srcMessagingHub),
            23,
            bytes32("1")
        );

        assertEq(rewardManager.epochRewardsPerPoint(nextEpoch), _ONE);
        assertEq(rewardManager.nextEpochToDeliver(), nextEpoch + 1);
        assertEq(
            usdc.balanceOf(address(rewardManager)),
            rewardManagerBalance + 100e6
        );
        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), daoBalance);

        rewardManager.notifyShutdown();
        rewardManagerBalance = usdc.balanceOf(address(rewardManager));

        nextEpoch = rewardManager.nextEpochToDeliver();

        vm.prank(_WORMHOLE_RELAYER);
        messagingHub.receiveWormholeMessages(
            abi.encode(3, nextEpoch, _ONE),
            additionalMessages,
            _addressToBytes32(srcMessagingHub),
            23,
            bytes32("2")
        );

        assertEq(rewardManager.epochRewardsPerPoint(nextEpoch), 0);
        assertEq(rewardManager.nextEpochToDeliver(), nextEpoch);
        assertEq(usdc.balanceOf(address(rewardManager)), rewardManagerBalance);
        assertEq(
            usdc.balanceOf(centralRegistry.daoAddress()),
            daoBalance + 100e6
        );
    }

    function test_receiveWormholeMessages_success_whenPayloadTypeIs4() public {
        _skipRestrictionDuration();

        centralRegistry.addLockingPermissions(address(messagingHub));

        assertEq(cve.balanceOf(address(messagingHub)), 0);
        assertEq(veCVE.balanceOf(user1), 0);

        address recipient = user1;
        uint256 amount = _ONE;
        bool continuousLock = true;

        vm.prank(_WORMHOLE_RELAYER);
        messagingHub.receiveWormholeMessages(
            abi.encode(4, recipient, amount, continuousLock),
            additionalMessages,
            _addressToBytes32(srcMessagingHub),
            23,
            bytes32("1")
        );

        assertEq(cve.balanceOf(address(messagingHub)), 0);
        assertEq(veCVE.balanceOf(user1), amount);
    }
}
