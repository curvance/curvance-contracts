// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseVotingHub } from "../TestBaseVotingHub.sol";
import { VotingHub } from "contracts/architecture/VotingHub.sol";
import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
import { EmissionData } from "contracts/interfaces/IMessagingHub.sol";
import { WormholeMock } from "tests/utils/WormholeMock.sol";
import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";

// FIX: Test
contract ExecuteEmissionConfigurationTest is TestBaseVotingHub {
    address public srcMessagingHub;
    address public srcVotingHub;
    uint256[] public gasLimit;
    EmissionData internal _emissionData;
    EmissionData[] internal _remoteEmissionData;

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

        deal(address(messagingHub), _ONE);

        gasLimit.push(250_000);

        _emissionData.tokens = new address[](1);
        _emissionData.emissions = new uint256[](1);

        _emissionData.emissionTotal = _ONE;
        _emissionData.tokens[0] = _USDC_ADDRESS;
        _emissionData.emissions[0] = _ONE;

        _remoteEmissionData.push(_emissionData);
    }

    function test_executeEmissionConfiguration_fail_whenCallerIsNotAuthorized()
        public
    {
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

    function test_executeEmissionConfiguration_fail_whenLengthIsMismatch()
        public
    {
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

        _emissionData.emissions = new uint256[](2);
        _emissionData.emissions[0] = _ONE;
        _emissionData.emissions[1] = _ONE;

        vm.expectRevert(VotingHub.VotingHub__InvalidParameter.selector);
        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );

        _remoteEmissionData[0] = _emissionData;
        _emissionData.emissions = new uint256[](1);
        _emissionData.emissions[0] = _ONE;

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

    function test_executeEmissionConfiguration_fail_EmptyParams() public {
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

        votingHub.setEraTargetEmissions(_ONE * 3);

        uint256 gaugePoolCVEBalance = cve.balanceOf(address(gaugeManager));

        bytes memory zeroResponse = new bytes(0);

        vm.expectRevert();
        votingHub.executeEmissionConfiguration(
            zeroResponse, // zero response data
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );

        IWormhole.Signature[] memory zeroSigs = new IWormhole.Signature[](0);

        vm.expectRevert();
        votingHub.executeEmissionConfiguration(
            response,
            zeroSigs, // zero signatures
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );

        uint256[] memory zeroGasLimit = new uint256[](0);

        vm.expectRevert();
        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            zeroGasLimit, // zero gas limit
            _emissionData,
            _remoteEmissionData
        );

        EmissionData memory zeroEmissionData;

        vm.expectRevert();
        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            zeroEmissionData, // zero emission data
            _remoteEmissionData
        );

        EmissionData[] memory zeroRemoteEmissionData = new EmissionData[](0);

        vm.expectRevert();
        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            zeroRemoteEmissionData // zero remote emission data
        );


    }

}
