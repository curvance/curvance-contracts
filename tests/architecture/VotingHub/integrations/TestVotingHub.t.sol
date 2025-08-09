// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;


import { VotingHub } from "contracts/architecture/VotingHub.sol";

import { EmissionData } from "contracts/interfaces/IMessagingHub.sol";
import { ChainConfig } from "contracts/interfaces/ICentralRegistry.sol";

import { WormholeHelper } from "@pigeon/src/wormhole/automatic-relayer/WormholeHelper.sol";
import { TestBaseVotingHub } from "../TestBaseVotingHub.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { WormholeMock } from "tests/utils/WormholeMock.sol";
import { Vm } from "forge-std/Vm.sol";

contract TestVotingHub is TestBaseVotingHub {
    uint256 public srcForkId;
    uint256 public dstForkId1;
    uint256 public dstForkId2;
    WormholeHelper public wormholeHelper;
    uint256[] public gasLimit;
    EmissionData internal _emissionData;
    EmissionData[] internal _remoteEmissionData;

    function setUp() public override {
        // Fork Ethereum as source chain and select it
        srcForkId = _fork(19140000);

        _CROSSCHAIN_CORES[block.chainid] = address(new WormholeMock());
        wormholeHelper = new WormholeHelper();

        // Deploy contracts on forked Ethereum.
        _init();

        // Fork Arbitrum as destination chain and select it
        dstForkId1 = _fork("ETH_NODE_URI_ARBITRUM", 176678420);

        // Deploy contracts on forked Arbitrum.
        _deployBaseContracts();
        _deployMarketManager();

        _skipEpochDuration(1);

        _prepareUSDC(address(rewardManager), 100000e6);

        centralRegistry.setMessageTransmitter(_CIRCLE_MESSAGE_TRANSMITTER);
        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );
        ChainConfig memory config;
        config.isSupported = true;
        config.messagingChainId = 2;
        config.domain = 0;
        config.messagingHub = address(messagingHubs[1]);
        config.votingHub = address(votingHubs[1]);
        config.cveAddress = address(cves[1]);
        config.feeTokenAddress = _USDC_ADDRESSES[1];
        config.crosschainRelayer = _CROSSCHAIN_RELAYERS[1];

        // Support Ethereum Mainnet on Arbitrum.
        centralRegistry.addChain(1, config);

        // Fork Optimism as destination chain and select it
        dstForkId2 = _fork("ETH_NODE_URI_OPTIMISM", 115634760);

        // Deploy contracts on forked Optimism.
        _deployBaseContracts();
        _deployMarketManager();

        _skipEpochDuration(1);

        _prepareUSDC(address(rewardManager), 100000e6);

        centralRegistry.setMessageTransmitter(_CIRCLE_MESSAGE_TRANSMITTER);
        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        config.messagingChainId = 2;
        config.domain = 0;
        config.messagingHub = address(messagingHubs[1]);
        config.votingHub = address(votingHubs[1]);
        config.cveAddress = address(cves[1]);
        config.feeTokenAddress = _USDC_ADDRESSES[1];
        config.crosschainRelayer = _CROSSCHAIN_RELAYERS[1];

        // Support Ethereum Mainnet on Optimism.
        centralRegistry.addChain(1, config);

        // Select forked Ethereum
        vm.selectFork(srcForkId);

        _initMainVariables();

        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = address(messagingHubs[42161]);
        config.votingHub = address(votingHubs[42161]);
        config.cveAddress = address(cve);
        config.feeTokenAddress = _USDC_ADDRESSES[42161];
        config.crosschainRelayer = _CROSSCHAIN_RELAYERS[42161];

        // Support chainId 42161.
        centralRegistry.addChain(42161, config);

        deal(address(messagingHub), _ONE);
    }

    function test_executeEmissionConfiguration_multipleChains_success() public {
        ChainConfig memory configTwo;
        configTwo.isSupported = 2;
        configTwo.messagingChainId = 24;
        configTwo.domain = 2;
        configTwo.messagingHub = address(messagingHubs[10]);
        configTwo.votingHub = address(votingHubs[10]);
        configTwo.cveAddress = address(cve);
        configTwo.feeTokenAddress = _USDC_ADDRESSES[10];
        configTwo.crosschainRelayer = _CROSSCHAIN_RELAYERS[10];

        // Support chainId 10.
        centralRegistry.addChain(10, configTwo);

        gasLimit.push(250_000);
        gasLimit.push(250_000);

        _emissionData.tokens = new address[](1);
        _emissionData.emissions = new uint256[](1);

        _emissionData.emissionTotal = _ONE;
        _emissionData.emissions[0] = _ONE;

        _emissionData.tokens[0] = _USDC_ADDRESSES[42161];
        _remoteEmissionData.push(_emissionData);

        _emissionData.tokens[0] = _USDC_ADDRESSES[10];
        _remoteEmissionData.push(_emissionData);

        _emissionData.tokens[0] = _USDC_ADDRESS;

        _skipEpochDuration(1);

        centralRegistry.setEraTargetEmissions(_ONE * 5);

        uint256 gaugePoolCVEBalance = cve.balanceOf(address(gaugeManager));

        vm.recordLogs();

        PerChainData[] memory perChainData = new PerChainData[](2);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            address(votingHubs[42161]),
            abi.encode(_ONE)
        );
        perChainData[1] = PerChainData(
            24,
            block.number,
            uint64(block.timestamp * 1000000),
            address(votingHubs[10]),
            abi.encode(_ONE)
        );

        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryEmissionsAllocated()")
        );

        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 totalWeights, uint256 poolWeight) = gaugeManager.gaugeWeight(
            gaugeManager.currentEpoch(),
            _USDC_ADDRESS
        );

        assertEq(
            cve.balanceOf(address(gaugeManager)),
            gaugePoolCVEBalance + _ONE
        );
        assertEq(totalWeights, _ONE);
        assertEq(poolWeight, _ONE);

        // Select forked Arbitrum
        vm.selectFork(dstForkId1);

        _initMainVariables();

        (totalWeights, poolWeight) = gaugeManager.gaugeWeight(
            gaugeManager.currentEpoch(),
            _USDC_ADDRESS
        );

        assertEq(cve.balanceOf(address(gaugeManager)), 0);
        assertEq(totalWeights, 0);
        assertEq(poolWeight, 0);

        // Select forked Optimism
        vm.selectFork(dstForkId2);

        _initMainVariables();

        (totalWeights, poolWeight) = gaugeManager.gaugeWeight(
            gaugeManager.currentEpoch(),
            _USDC_ADDRESS
        );

        assertEq(cve.balanceOf(address(gaugeManager)), 0);
        assertEq(totalWeights, 0);
        assertEq(poolWeight, 0);

        // Select forked Ethereum
        vm.selectFork(srcForkId);

        _initMainVariables();

        // Simulate wormhole cross-chain messaging with payloadType 2
        uint256[] memory dstForkIds = new uint256[](2);
        address[] memory expDstAddresses = new address[](2);
        address[] memory dstRelayers = new address[](2);

        dstForkIds[0] = dstForkId1;
        dstForkIds[1] = dstForkId2;
        expDstAddresses[0] = address(messagingHubs[42161]);
        expDstAddresses[1] = address(messagingHubs[10]);
        dstRelayers[0] = _CROSSCHAIN_RELAYERS[42161];
        dstRelayers[1] = _CROSSCHAIN_RELAYERS[10];

        wormholeHelper.help(2, dstForkIds, expDstAddresses, dstRelayers, logs);

        // Select forked Arbitrum
        vm.selectFork(dstForkId1);

        _initMainVariables();

        (totalWeights, poolWeight) = gaugeManager.gaugeWeight(
            gaugeManager.currentEpoch(),
            _USDC_ADDRESS
        );

        assertEq(cve.balanceOf(address(gaugeManager)), _ONE);
        assertEq(totalWeights, _ONE);
        assertEq(poolWeight, _ONE);

        // Select forked Optimism
        vm.selectFork(dstForkId2);

        _initMainVariables();

        (totalWeights, poolWeight) = gaugeManager.gaugeWeight(
            gaugeManager.currentEpoch(),
            _USDC_ADDRESS
        );

        assertEq(cve.balanceOf(address(gaugeManager)), _ONE);
        assertEq(totalWeights, _ONE);
        assertEq(poolWeight, _ONE);
    }

    function test_executeEmissionConfiguration_multipleTimes_success() public {
        gasLimit.push(250_000);

        _emissionData.tokens = new address[](1);
        _emissionData.emissions = new uint256[](1);

        _emissionData.tokens[0] = _USDC_ADDRESSES[42161];
        _remoteEmissionData.push(_emissionData);

        _emissionData.emissionTotal = _ONE / 2;
        _emissionData.emissions[0] = _ONE / 2;
        _emissionData.tokens[0] = _USDC_ADDRESS;

        _skipEpochDuration(1);

        centralRegistry.setEraTargetEmissions(_ONE);

        uint256 gaugePoolCVEBalance = cve.balanceOf(address(gaugeManager));

        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            address(votingHubs[42161]),
            abi.encode(0)
        );

        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryEmissionsAllocated()")
        );

        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );

        (uint256 totalWeights, uint256 poolWeight) = gaugeManager.gaugeWeight(
            gaugeManager.currentEpoch(),
            _USDC_ADDRESS
        );

        assertEq(
            cve.balanceOf(address(gaugeManager)),
            gaugePoolCVEBalance + _ONE / 2
        );
        assertEq(totalWeights, _ONE / 2);
        assertEq(poolWeight, _ONE / 2);

        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryEmissionsAllocated()")
        );

        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );

        (totalWeights, poolWeight) = gaugeManager.gaugeWeight(
            gaugeManager.currentEpoch(),
            _USDC_ADDRESS
        );

        assertEq(
            cve.balanceOf(address(gaugeManager)),
            gaugePoolCVEBalance + _ONE
        );
        assertEq(totalWeights, _ONE);
        assertEq(poolWeight, _ONE);
    }

    function test_executeEmissionConfiguration_increaseRewardAfterEpochAndEra_success()
        public
    {
        gasLimit.push(250_000);

        _emissionData.tokens = new address[](1);
        _emissionData.emissions = new uint256[](1);

        _emissionData.tokens[0] = _USDC_ADDRESSES[42161];
        _remoteEmissionData.push(_emissionData);

        _emissionData.emissionTotal = _ONE;
        _emissionData.emissions[0] = _ONE;
        _emissionData.tokens[0] = _USDC_ADDRESS;

        _skipEpochDuration(1);

        centralRegistry.setEraTargetEmissions(_ONE * 3);

        uint256 gaugePoolCVEBalance = cve.balanceOf(address(gaugeManager));

        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            address(votingHubs[42161]),
            abi.encode(0)
        );

        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryEmissionsAllocated()")
        );

        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );

        (uint256 totalWeights, uint256 poolWeight) = gaugeManager.gaugeWeight(
            gaugeManager.currentEpoch(),
            _USDC_ADDRESS
        );

        assertEq(
            cve.balanceOf(address(gaugeManager)),
            gaugePoolCVEBalance + _ONE
        );
        assertEq(totalWeights, _ONE);
        assertEq(poolWeight, _ONE);

        skip(votingHub.EPOCH_DURATION() * 5);

        centralRegistry.setEraTargetEmissions(_ONE * 5);

        _emissionData.emissionTotal = _ONE * 2;
        _emissionData.emissions[0] = _ONE * 2;

        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            address(votingHubs[42161]),
            abi.encode(0)
        );

        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryEmissionsAllocated()")
        );

        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );

        (totalWeights, poolWeight) = gaugeManager.gaugeWeight(
            gaugeManager.currentEpoch(),
            _USDC_ADDRESS
        );

        assertEq(
            cve.balanceOf(address(gaugeManager)),
            gaugePoolCVEBalance + _ONE * 3
        );
        assertEq(totalWeights, _ONE * 2);
        assertEq(poolWeight, _ONE * 2);

        skip(votingHub.EPOCH_DURATION() * votingHub.REWARD_HALVENING_RATE());

        centralRegistry.setEraTargetEmissions(_ONE * 10);

        _emissionData.emissionTotal = _ONE * 3;
        _emissionData.emissions[0] = _ONE * 3;

        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            address(votingHubs[42161]),
            abi.encode(0)
        );

        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryEmissionsAllocated()")
        );

        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );

        (totalWeights, poolWeight) = gaugeManager.gaugeWeight(
            gaugeManager.currentEpoch(),
            _USDC_ADDRESS
        );

        assertEq(
            cve.balanceOf(address(gaugeManager)),
            gaugePoolCVEBalance + _ONE * 6
        );
        assertEq(totalWeights, _ONE * 3);
        assertEq(poolWeight, _ONE * 3);
    }

    function test_executeEmissionConfiguration_remintForPreviousEpoch_fail()
        public
    {
        gasLimit.push(250_000);

        _emissionData.tokens = new address[](1);
        _emissionData.emissions = new uint256[](1);

        _emissionData.tokens[0] = _USDC_ADDRESSES[42161];
        _remoteEmissionData.push(_emissionData);

        _emissionData.emissionTotal = _ONE;
        _emissionData.emissions[0] = _ONE;
        _emissionData.tokens[0] = _USDC_ADDRESS;

        _skipEpochDuration(1);

        centralRegistry.setEraTargetEmissions(_ONE * 3);

        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            address(votingHubs[42161]),
            abi.encode(0)
        );

        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryEmissionsAllocated()")
        );

        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );

        skip(votingHub.EPOCH_DURATION());

        vm.expectRevert(bytes4(keccak256("StaleBlockTime()")));
        votingHub.executeEmissionConfiguration(
            response,
            signatures,
            gasLimit,
            _emissionData,
            _remoteEmissionData
        );
    }
}
