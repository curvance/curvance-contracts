// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMessagingHub } from "../TestBaseMessagingHub.sol";
import { MessagingHub } from "contracts/architecture/MessagingHub.sol";
import { WormholeMock } from "tests/utils/WormholeMock.sol";

contract ExecuteEpochTest is TestBaseMessagingHub {
    address public srcMessagingHub;
    address public srcVotingHub;

    function setUp() public override {
        _fork(19140000);

        srcMessagingHub = makeAddr("SrcMessagingHub");
        srcVotingHub = makeAddr("SrcVotingHub");
        _WORMHOLE_CORES[block.chainid] = address(new WormholeMock());

        _init();

        centralRegistry.addChainSupport(
            srcMessagingHub,
            srcVotingHub,
            address(cve),
            _USDC_ADDRESSES[42161],
            42161,
            23,
            makeAddr("Wormhole Relayer"),
            3
        );

        _skipEpochDuration(2);
    }

    function test_executeEpoch_fail_whenCurrentEpochIsEarlierThanNextEpochToDeliver()
        public
    {
        vm.warp(block.timestamp - rewardManager.epochDuration() * 2);

        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            srcMessagingHub,
            abi.encode(_ONE)
        );
        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert();
        messagingHub.executeEpoch(response, signatures, 100e6, 250_000);
    }

    function test_executeEpoch_fail_whenNumResponseIsMismatch() public {
        centralRegistry.addChainSupport(
            address(this),
            address(this),
            address(1),
            _USDC_ADDRESSES[10],
            10,
            24,
            makeAddr("Wormhole Relayer"),
            2
        );

        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            srcMessagingHub,
            abi.encode(_ONE)
        );
        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        messagingHub.executeEpoch(response, signatures, 100e6, 250_000);
    }

    function test_executeEpoch_fail_whenResultIsNotNumber() public {
        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            srcMessagingHub,
            abi.encode("wrong")
        );
        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        messagingHub.executeEpoch(response, signatures, 100e6, 250_000);
    }

    function test_executeEpoch_fail_whenBlockTimeIsStale() public {
        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64((block.timestamp - 1000) * 1000000),
            srcMessagingHub,
            abi.encode(_ONE)
        );
        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert(bytes4(keccak256("StaleBlockTime()")));
        messagingHub.executeEpoch(response, signatures, 100e6, 250_000);
    }

    function test_executeEpoch_fail_whenChainIdIsInvalid() public {
        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            24,
            block.number,
            uint64(block.timestamp * 1000000),
            srcMessagingHub,
            abi.encode(_ONE)
        );
        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        messagingHub.executeEpoch(response, signatures, 100e6, 250_000);
    }

    function test_executeEpoch_fail_whenToAddressIsInvalid() public {
        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            address(1),
            abi.encode(_ONE)
        );
        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert(bytes4(keccak256("InvalidContractAddress()")));
        messagingHub.executeEpoch(response, signatures, 100e6, 250_000);
    }

    function test_executeEpoch_fail_whenCallDataIsInvalid() public {
        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            srcMessagingHub,
            abi.encode(_ONE)
        );
        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("wrong()")
        );

        vm.expectRevert(bytes4(keccak256("InvalidFunctionSignature()")));
        messagingHub.executeEpoch(response, signatures, 100e6, 250_000);
    }

    function test_executeEpoch_success() public {
        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            srcMessagingHub,
            abi.encode(_ONE)
        );
        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryLockPoints()")
        );

        deal(address(messagingHub), _ONE);
        deal(_USDC_ADDRESS, address(feeManager), 100e6);

        uint256 compoundingFee = (100e6 *
            centralRegistry.protocolCompoundFee()) /
            centralRegistry.protocolHarvestFee();

        assertEq(usdc.balanceOf(address(messagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeManager)), 100e6);
        assertEq(usdc.balanceOf(address(this)), 0);

        messagingHub.executeEpoch(response, signatures, 100e6, 250_000);

        assertEq(usdc.balanceOf(address(messagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeManager)), 0);
        assertEq(usdc.balanceOf(address(this)), compoundingFee);

        deal(_USDC_ADDRESS, address(feeManager), 100e6);

        rewardManager.notifyShutdown();

        assertEq(usdc.balanceOf(address(feeManager)), 100e6);

        messagingHub.executeEpoch(response, signatures, 100e6, 250_000);

        assertEq(usdc.balanceOf(address(messagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeManager)), 0);
        assertEq(usdc.balanceOf(address(this)), 100e6 + compoundingFee);
    }
}
