// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { VotingHub } from "contracts/architecture/VotingHub.sol";
import { GaugeManager } from "contracts/architecture/GaugeManager.sol";

import { EmissionData } from "contracts/interfaces/IMessagingHub.sol";
import { ChainConfig } from "contracts/interfaces/ICentralRegistry.sol";

import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";

import { TestBaseVotingHub } from "../TestBaseVotingHub.sol";
import { WormholeMock } from "tests/utils/WormholeMock.sol";

// Explicit public function testing
contract VotingHubPublicFunctionsTest is TestBaseVotingHub {
    address public srcMessagingHub;
    address public srcVotingHub;
    uint256[] public gasLimit;
    EmissionData internal _emissionData;
    EmissionData[] internal _remoteEmissionData;

    function setUp() public override {
        _fork(19140000);

        srcMessagingHub = makeAddr("SrcMessagingHub");
        srcVotingHub = makeAddr("SrcVotingHub");
        _CROSSCHAIN_CORES[block.chainid] = address(new WormholeMock());

        _init();

        ChainConfig memory config;
        config.isSupported = 2;
        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = srcMessagingHub;
        config.votingHub = srcVotingHub;
        config.cveAddress = address(cve);
        config.feeTokenAddress = _USDC_ADDRESSES[42161];
        config.crosschainRelayer = makeAddr("Wormhole Relayer");

        // Support chainId 42161.
        centralRegistry.addChain(42161, config);

        deal(address(messagingHub), _ONE);

        gasLimit.push(250_000);

        _emissionData.tokens = new address[](1);
        _emissionData.emissions = new uint256[](1);

        _emissionData.emissionTotal = _ONE;
        _emissionData.tokens[0] = _USDC_ADDRESS;
        _emissionData.emissions[0] = _ONE;

        _remoteEmissionData.push(_emissionData);

        _skipEpochDuration(1);

        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            srcVotingHub,
            abi.encode(_ONE)
        );

        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryEmissionsAllocated()")
        );

        centralRegistry.setEraTargetEmissions(_ONE * 3);

        uint256 gaugePoolCVEBalance = cve.balanceOf(address(gaugeManager));

        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );

        (uint256 totalWeights, uint256 poolWeight) = gaugeManager.gaugeWeight(
            1,
            _USDC_ADDRESS
        );

        assertEq(
            cve.balanceOf(address(gaugeManager)),
            gaugePoolCVEBalance + _ONE
        );
        assertEq(totalWeights, _ONE);
        assertEq(poolWeight, _ONE);
    }

    // is tested implicitly in ExecuteEmissionConfigurationTest but tested
    // for completeness
    function test_queryEmissionsAllocated() public {
        uint256 queryEmissionsAllocated = votingHub.queryEmissionsAllocated();
        assertEq(queryEmissionsAllocated, 2 * _ONE);
    }

    function test_currentTargetEmissions() public {
        uint256 currentTargetEmissions = votingHub.currentTargetEmissions();
        assertEq(currentTargetEmissions, 3 * _ONE);
    }

    function test_currentEra_next() public {
        _skipEpochDuration(27);
        uint256 currentEra = votingHub.currentEra();
        assertEq(currentEra, 1);
    }

    function test_epochOfTimestamp() public {
        uint256 epoch_duration = centralRegistry.EPOCH_DURATION();
        uint256 epochOfTimestampCurrent = votingHub.epochOfTimestamp(block.timestamp);
        assertEq(epochOfTimestampCurrent, 1);

        uint256 epochOfTimestampFuture = votingHub.epochOfTimestamp(block.timestamp + (epoch_duration * 2));
        assertEq(epochOfTimestampFuture, 3);
    }



}
