// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseProtocolMessagingHub } from "../TestBaseProtocolMessagingHub.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";
import { stdStorage, StdStorage } from "forge-std/Test.sol";

contract ProtocolMessagingHubReceiveWormholeMessagesTest is
    TestBaseProtocolMessagingHub
{
    using stdStorage for StdStorage;

    address public srcMessagingHub;

    function setUp() public override {
        super.setUp();

        srcMessagingHub = makeAddr("SrcMessagingHub");

        centralRegistry.addChainSupport(
            address(srcMessagingHub),
            address(srcMessagingHub),
            address(cve),
            _USDC_ADDRESS,
            42161,
            1,
            1,
            23
        );
    }

    function test_receiveWormholeMessages_fail_whenCallerIsNotWormholeRelayer()
        public
    {
        vm.expectRevert(
            ProtocolMessagingHub.ProtocolMessagingHub__Unauthorized.selector
        );
        protocolMessagingHub.receiveWormholeMessages(
            abi.encode(1, bytes32(uint256(uint160(_USDC_ADDRESS))), 100e6),
            new bytes[](0),
            bytes32(uint256(uint160(address(srcMessagingHub)))),
            23,
            bytes32("0x01")
        );
    }

    function test_receiveWormholeMessages_fail_whenNotReceivedToken() public {
        vm.prank(_WORMHOLE_RELAYER);

        vm.expectRevert();
        protocolMessagingHub.receiveWormholeMessages(
            abi.encode(1, bytes32(uint256(uint160(_USDC_ADDRESS))), 100e6),
            new bytes[](0),
            bytes32(uint256(uint160(address(srcMessagingHub)))),
            23,
            bytes32("0x01")
        );
    }

    function test_receiveWormholeMessages_fail_whenMessagingHubIsPaused()
        public
    {
        protocolMessagingHub.flipMessagingHubStatus();

        vm.prank(_WORMHOLE_RELAYER);

        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__MessagingHubPaused
                .selector
        );
        protocolMessagingHub.receiveWormholeMessages(
            abi.encode(1, bytes32(uint256(uint160(_USDC_ADDRESS))), 100e6),
            new bytes[](0),
            bytes32(uint256(uint160(address(srcMessagingHub)))),
            23,
            bytes32("0x01")
        );
    }

    function test_receiveWormholeMessages_fail_whenMessageIsAlreadyDelivered()
        public
    {
        deal(_USDC_ADDRESS, address(protocolMessagingHub), 100e6);

        vm.startPrank(_WORMHOLE_RELAYER);

        protocolMessagingHub.receiveWormholeMessages(
            abi.encode(1, bytes32(uint256(uint160(_USDC_ADDRESS))), 100e6),
            new bytes[](0),
            bytes32(uint256(uint160(address(srcMessagingHub)))),
            23,
            bytes32("0x01")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolMessagingHub
                    .ProtocolMessagingHub__MessageHashIsAlreadyDelivered
                    .selector,
                bytes32("0x01")
            )
        );
        protocolMessagingHub.receiveWormholeMessages(
            abi.encode(1, bytes32(uint256(uint160(_USDC_ADDRESS))), 100e6),
            new bytes[](0),
            bytes32(uint256(uint160(address(srcMessagingHub)))),
            23,
            bytes32("0x01")
        );

        vm.stopPrank();
    }

    function test_receiveWormholeMessages_success_whenSourceAddressIsNotMessagingHub()
        public
    {
        deal(_USDC_ADDRESS, address(protocolMessagingHub), 100e6);

        vm.prank(_WORMHOLE_RELAYER);
        protocolMessagingHub.receiveWormholeMessages(
            abi.encode(1, bytes32(uint256(uint160(_USDC_ADDRESS))), 100e6),
            new bytes[](0),
            bytes32(0),
            23,
            bytes32("0x01")
        );

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 100e6);
        assertEq(usdc.balanceOf(address(cveLocker)), 0);
    }

    function test_receiveWormholeMessages_success_whenOperatorIsNotAuthorized()
        public
    {
        stdstore
            .target(address(centralRegistry))
            .sig("omnichainOperators(address,uint256)")
            .with_key(address(srcMessagingHub))
            .with_key(42161)
            .depth(0)
            .checked_write(1);

        deal(_USDC_ADDRESS, address(protocolMessagingHub), 100e6);

        vm.prank(_WORMHOLE_RELAYER);
        protocolMessagingHub.receiveWormholeMessages(
            abi.encode(1, bytes32(uint256(uint160(_USDC_ADDRESS))), 100e6),
            new bytes[](0),
            bytes32(uint256(uint160(address(srcMessagingHub)))),
            23,
            bytes32("0x01")
        );

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 100e6);
        assertEq(usdc.balanceOf(address(cveLocker)), 0);
    }

    function test_receiveWormholeMessages_success_whenPayloadTypeIs1() public {
        deal(_USDC_ADDRESS, address(protocolMessagingHub), 100e6);

        assertEq(usdc.balanceOf(address(cveLocker)), 0);

        vm.prank(_WORMHOLE_RELAYER);
        protocolMessagingHub.receiveWormholeMessages(
            abi.encode(1, bytes32(uint256(uint160(_USDC_ADDRESS))), 100e6),
            new bytes[](0),
            bytes32(uint256(uint160(address(srcMessagingHub)))),
            23,
            bytes32("0x01")
        );

        uint256 oneBalanceFee = (100e6 *
            centralRegistry.protocolCompoundFee()) /
            centralRegistry.protocolHarvestFee();

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(centralRegistry)), oneBalanceFee);
        assertEq(usdc.balanceOf(address(cveLocker)), 100e6 - oneBalanceFee);

        deal(_USDC_ADDRESS, address(protocolMessagingHub), 100e6);

        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), 0);

        cveLocker.notifyLockerShutdown();

        vm.prank(_WORMHOLE_RELAYER);
        protocolMessagingHub.receiveWormholeMessages(
            abi.encode(1, bytes32(uint256(uint160(_USDC_ADDRESS))), 100e6),
            new bytes[](0),
            bytes32(uint256(uint160(address(srcMessagingHub)))),
            23,
            bytes32("0x02")
        );

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(centralRegistry)), oneBalanceFee * 2);
        assertEq(
            usdc.balanceOf(centralRegistry.daoAddress()),
            100e6 - oneBalanceFee
        );
    }

    function test_receiveWormholeMessages_success_whenPayloadTypeIs2() public {
        address[] memory gaugePools = new address[](1);
        uint256[] memory emissionTotals = new uint256[](1);
        address[][] memory tokens = new address[][](1);
        uint256[][] memory emissions = new uint256[][](1);

        tokens[0] = new address[](1);
        emissions[0] = new uint256[](1);

        gaugePools[0] = address(gaugePool);
        emissionTotals[0] = _ONE;
        tokens[0][0] = _USDC_ADDRESS;
        emissions[0][0] = _ONE;

        gaugePool.start(address(marketManager));

        vm.warp(veCVE.nextEpochStartTime() + 100);

        vm.prank(_WORMHOLE_RELAYER);
        protocolMessagingHub.receiveWormholeMessages(
            abi.encode(
                2,
                abi.encode(gaugePools, emissionTotals, tokens, emissions)
            ),
            new bytes[](0),
            bytes32(uint256(uint160(address(srcMessagingHub)))),
            23,
            bytes32("0x01")
        );

        (uint256 totalWeights, uint256 poolWeight) = gaugePool.gaugeWeight(
            gaugePool.currentEpoch() + 1,
            _USDC_ADDRESS
        );

        assertEq(totalWeights, _ONE);
        assertEq(poolWeight, _ONE);
        assertEq(cve.balanceOf(address(gaugePool)), _ONE);
    }

    function test_receiveWormholeMessages_success_whenPayloadTypeIs3() public {
        uint256 chainLockedAmount = _ONE;

        uint256 nextEpoch = cveLocker.nextEpochToDeliver();

        assertEq(cveLocker.epochRewardsPerCVE(nextEpoch), 0);

        vm.prank(_WORMHOLE_RELAYER);
        protocolMessagingHub.receiveWormholeMessages(
            abi.encode(3, chainLockedAmount),
            new bytes[](0),
            bytes32(uint256(uint160(address(srcMessagingHub)))),
            23,
            bytes32("0x01")
        );

        assertEq(cveLocker.epochRewardsPerCVE(nextEpoch), _ONE);
        assertEq(cveLocker.nextEpochToDeliver(), nextEpoch + 1);
    }

    function test_receiveWormholeMessages_success_whenPayloadTypeIs4() public {
        vm.prank(centralRegistry.protocolMessagingHub());
        cveLocker.recordEpochRewards(_ONE);

        skip(veCVE.RESTRICTION_DURATION() + 1);

        centralRegistry.addVeCVELocker(address(protocolMessagingHub));

        assertEq(cve.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(veCVE.balanceOf(user1), 0);

        address recipient = user1;
        uint256 amount = _ONE;
        bool continuousLock = true;

        vm.prank(_WORMHOLE_RELAYER);
        protocolMessagingHub.receiveWormholeMessages(
            abi.encode(4, recipient, amount, continuousLock),
            new bytes[](0),
            bytes32(uint256(uint160(address(srcMessagingHub)))),
            23,
            bytes32("0x01")
        );

        assertEq(cve.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(veCVE.balanceOf(user1), amount);
    }
}
