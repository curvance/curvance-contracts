// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { MessagingHub } from "contracts/architecture/MessagingHub.sol";

import { ChainConfig } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseMessagingHub } from "../TestBaseMessagingHub.sol";
import { WormholeMock } from "tests/utils/WormholeMock.sol";

contract ExecuteEpochTest is TestBaseMessagingHub {
    address public srcMessagingHub;
    address public srcVotingHub;

    function setUp() public override {
        _fork(19140000);

        srcMessagingHub = makeAddr("SrcMessagingHub");
        srcVotingHub = makeAddr("SrcVotingHub");
        _CROSSCHAIN_CORES[block.chainid] = address(new WormholeMock());

        _init();

        ChainConfig memory config;
        config.isSupported = true;
        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = srcMessagingHub;
        config.votingHub = srcVotingHub;
        config.cveAddress = address(cve);
        config.feeTokenAddress =  _USDC_ADDRESSES[42161];
        config.crosschainRelayer = makeAddr("Wormhole Relayer");

        // Support chainId 42161.
        centralRegistry.addChain(42161, config);

        _skipEpochDuration(1);
    }

    function test_executeEpoch_fail_whenCurrentEpochIsEarlierThanNextEpochToDeliver()
        public
    {
        vm.warp(block.timestamp - rewardManager.EPOCH_DURATION() * 2);

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
        ChainConfig memory configTwo;
        configTwo.isSupported = true;
        configTwo.messagingChainId = 24;
        configTwo.domain = 2;
        configTwo.messagingHub = address(this);
        configTwo.votingHub = address(this);
        configTwo.cveAddress = address(1);
        configTwo.feeTokenAddress = _USDC_ADDRESSES[10];
        configTwo.crosschainRelayer = makeAddr("Wormhole Relayer");

        // Support chainId 10.
        centralRegistry.addChain(10, configTwo);

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
        _prepareUSDC(address(feeManager), 100e6);

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

        _prepareUSDC(address(feeManager), 100e6);

        rewardManager.notifyShutdown();

        assertEq(usdc.balanceOf(address(feeManager)), 100e6);

        _skipEpochDuration(1);

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

        messagingHub.executeEpoch(response, signatures, 100e6, 250_000);

        assertEq(usdc.balanceOf(address(messagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeManager)), 0);
        assertEq(usdc.balanceOf(address(this)), 100e6 + compoundingFee);
    }
}
