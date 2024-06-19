// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseProtocolMessagingHub } from "../TestBaseProtocolMessagingHub.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";
import { WormholeMock } from "tests/utils/WormholeMock.sol";

contract ExecuteEpochTest is TestBaseProtocolMessagingHub {
    address public srcMessagingHub;

    function setUp() public override {
        _fork(19140000);

        srcMessagingHub = makeAddr("SrcMessagingHub");
        _WORMHOLE_CORES[block.chainid] = address(new WormholeMock());

        _init();

        centralRegistry.addChainSupport(
            srcMessagingHub,
            address(cve),
            _USDC_ADDRESS,
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
        vm.warp(block.timestamp - rewardManager.EPOCH_DURATION() * 2);

        _prepareResponseAndSignatures(
            abi.encode(_ONE),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            srcMessagingHub,
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert();
        protocolMessagingHub.executeEpoch(
            response,
            signatures,
            100e6,
            250_000
        );
    }

    function test_executeEpoch_fail_whenResultIsNotNumber() public {
        _prepareResponseAndSignatures(
            abi.encode("wrong"),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            srcMessagingHub,
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__InvalidParameter
                .selector
        );
        protocolMessagingHub.executeEpoch(
            response,
            signatures,
            100e6,
            250_000
        );
    }

    function test_executeEpoch_fail_whenBlockTimeIsStale() public {
        _prepareResponseAndSignatures(
            abi.encode(_ONE),
            block.number,
            uint64((block.timestamp - 1000) * 1000000),
            23,
            srcMessagingHub,
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert(bytes4(keccak256("StaleBlockTime()")));
        protocolMessagingHub.executeEpoch(
            response,
            signatures,
            100e6,
            250_000
        );
    }

    function test_executeEpoch_fail_whenChainIdIsInvalid() public {
        _prepareResponseAndSignatures(
            abi.encode(_ONE),
            block.number,
            uint64(block.timestamp * 1000000),
            24,
            srcMessagingHub,
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__InvalidParameter
                .selector
        );
        protocolMessagingHub.executeEpoch(
            response,
            signatures,
            100e6,
            250_000
        );
    }

    function test_executeEpoch_fail_whenToAddressIsInvalid() public {
        _prepareResponseAndSignatures(
            abi.encode(_ONE),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            address(1),
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert(bytes4(keccak256("InvalidContractAddress()")));
        protocolMessagingHub.executeEpoch(
            response,
            signatures,
            100e6,
            250_000
        );
    }

    function test_executeEpoch_fail_whenCallDataIsInvalid() public {
        _prepareResponseAndSignatures(
            abi.encode(_ONE),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            srcMessagingHub,
            abi.encodeWithSignature("wrong()")
        );

        vm.expectRevert(bytes4(keccak256("InvalidFunctionSignature()")));
        protocolMessagingHub.executeEpoch(
            response,
            signatures,
            100e6,
            250_000
        );
    }

    function test_executeEpoch_success() public {
        _prepareResponseAndSignatures(
            abi.encode(_ONE),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            srcMessagingHub,
            abi.encodeWithSignature("queryLockPoints()")
        );

        deal(address(protocolMessagingHub), _ONE);
        deal(_USDC_ADDRESS, address(feeAccumulator), 100e6);

        uint256 compoundingFee = (100e6 *
            centralRegistry.protocolCompoundFee()) /
            centralRegistry.protocolHarvestFee();

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeAccumulator)), 100e6);
        assertEq(usdc.balanceOf(address(this)), 0);

        protocolMessagingHub.executeEpoch(
            response,
            signatures,
            100e6,
            250_000
        );

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeAccumulator)), 0);
        assertEq(usdc.balanceOf(address(this)), compoundingFee);
    }
}
