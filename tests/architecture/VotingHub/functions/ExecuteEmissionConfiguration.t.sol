// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseVotingHub } from "../TestBaseVotingHub.sol";
import { VotingHub } from "contracts/architecture/VotingHub.sol";
import { GaugeErrors } from "contracts/gauge/GaugeErrors.sol";
import { EmissionData } from "contracts/interfaces/IMessagingHub.sol";
import { WormholeMock } from "tests/utils/WormholeMock.sol";

contract ExecuteEmissionConfigurationTest is TestBaseVotingHub {
    address public srcMessagingHub;
    uint256[] public gasLimit;
    EmissionData internal _emissionData;
    EmissionData[] internal _remoteEmissionData;

    function setUp() public override {
        _fork(19140000);

        srcMessagingHub = makeAddr("SrcMessagingHub");
        _WORMHOLE_CORES[block.chainid] = address(new WormholeMock());

        _init();

        centralRegistry.addChainSupport(
            srcMessagingHub,
            address(cve),
            _USDC_ADDRESSES[42161],
            42161,
            23,
            makeAddr("Wormhole Relayer"),
            3
        );

        deal(address(messagingHub), _ONE);

        gasLimit.push(250_000);

        _emissionData.gaugePools = new address[](1);
        _emissionData.emissionTotals = new uint256[](1);
        _emissionData.tokens = new address[][](1);
        _emissionData.emissions = new uint256[][](1);

        _emissionData.tokens[0] = new address[](1);
        _emissionData.emissions[0] = new uint256[](1);

        _emissionData.gaugePools[0] = address(gaugePool);
        _emissionData.emissionTotals[0] = _ONE;
        _emissionData.tokens[0][0] = _USDC_ADDRESS;
        _emissionData.emissions[0][0] = _ONE;

        _remoteEmissionData.push(_emissionData);
    }

    function test_executeEmissionConfiguration_fail_whenCallerIsNotAuthorized()
        public
    {
        gaugePool.start(address(marketManager));
        _skipEpochDuration(2);

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
            abi.encodeWithSignature("queryEmissionsAllocated()")
        );

        votingHub.setEraTargetEmissions(_ONE * 3);

        vm.prank(user1);

        vm.expectRevert(VotingHub.VotingHub__Unauthorized.selector);
        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );
    }

    function test_executeEmissionConfiguration_fail_whenGaugePoolIsNotStarted()
        public
    {
        _skipEpochDuration(2);

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
            abi.encodeWithSignature("queryEmissionsAllocated()")
        );

        votingHub.setEraTargetEmissions(_ONE * 3);

        vm.expectRevert(GaugeErrors.NotStarted.selector);
        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );
    }

    function test_executeEmissionConfiguration_fail_whenLengthIsMismatch()
        public
    {
        gaugePool.start(address(marketManager));

        _skipEpochDuration(2);

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
            abi.encodeWithSignature("queryEmissionsAllocated()")
        );

        votingHub.setEraTargetEmissions(_ONE * 3);

        _emissionData.emissions[0] = new uint256[](2);
        _emissionData.emissions[0][0] = _ONE;
        _emissionData.emissions[0][1] = _ONE;

        vm.expectRevert(VotingHub.VotingHub__InvalidParameter.selector);
        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );

        _remoteEmissionData[0] = _emissionData;
        _emissionData.emissions[0] = new uint256[](1);
        _emissionData.emissions[0][0] = _ONE;

        vm.expectRevert(VotingHub.VotingHub__InvalidParameter.selector);
        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );
    }

    function test_executeEmissionConfiguration_fail_whenExceedsCurrentTargetEmission()
        public
    {
        gaugePool.start(address(marketManager));

        _skipEpochDuration(2);

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
            abi.encodeWithSignature("queryEmissionsAllocated()")
        );

        vm.expectRevert(VotingHub.VotingHub__InvalidParameter.selector);
        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );
    }

    function test_executeEmissionConfiguration_success() public {
        gaugePool.start(address(marketManager));

        _skipEpochDuration(2);

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
            abi.encodeWithSignature("queryEmissionsAllocated()")
        );

        votingHub.setEraTargetEmissions(_ONE * 3);

        uint256 gaugePoolCVEBalance = cve.balanceOf(address(gaugePool));

        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );

        (uint256 totalWeights, uint256 poolWeight) = gaugePool.gaugeWeight(
            1,
            _USDC_ADDRESS
        );

        assertEq(
            cve.balanceOf(address(gaugePool)),
            gaugePoolCVEBalance + _ONE
        );
        assertEq(totalWeights, _ONE);
        assertEq(poolWeight, _ONE);
    }
}
