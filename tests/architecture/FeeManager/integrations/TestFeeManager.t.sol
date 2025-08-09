// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { MessagingHub } from "contracts/architecture/MessagingHub.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { WAD, WAD_SQUARED } from "contracts/libraries/ConstantsLib.sol";

import { ChainConfig } from "contracts/interfaces/ICentralRegistry.sol";
import { ClaimAction } from "contracts/interfaces/IRewardManager.sol";

import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";

import { WormholeHelper } from "@pigeon/src/wormhole/automatic-relayer/WormholeHelper.sol";
import { TestBaseFeeManager } from "../TestBaseFeeManager.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { WormholeMock } from "tests/utils/WormholeMock.sol";
import { Vm } from "forge-std/Vm.sol";

contract TestFeeManager is TestBaseFeeManager {
    uint256 public srcForkId;
    uint256 public dstForkId;
    WormholeHelper public wormholeHelper;
    ClaimAction public action = ClaimAction(true, false, false, false);

    function setUp() public override {
        // Fork Ethereum as source chain and select it
        srcForkId = _fork(19140000);

        _CROSSCHAIN_CORES[block.chainid] = address(new WormholeMock());

        // Deploy contracts on forked Ethereum
        _init();

        // Fork Arbitrum as destination chain and select it
        dstForkId = _fork("ETH_NODE_URI_ARBITRUM", 180000000);

        wormholeHelper = new WormholeHelper();

        // Deploy contracts on forked Arbitrum
        _deployBaseContracts();

        centralRegistry.setMessageTransmitter(_CIRCLE_MESSAGE_TRANSMITTER);
        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        ChainConfig memory config;
        config.isSupported = 2;
        config.messagingChainId = 2;
        config.domain = 0;
        config.messagingHub = address(messagingHubs[1]);
        config.votingHub = address(votingHubs[1]);
        config.cveAddress = address(cves[1]);
        config.feeTokenAddress = _USDC_ADDRESSES[1];
        config.crosschainRelayer = makeAddr("Wormhole Relayer");

        // Support chainId 1.
        centralRegistry.addChain(1, config);

        _prepareUSDC(address(rewardManager), 100000e6);
        _prepareUSDC(address(this), 100000e6);
        _prepareCVE(address(this), 100e18);

        usdc.approve(_UNISWAP_V2_ROUTER, 100000e6);
        cve.approve(_UNISWAP_V2_ROUTER, 100e18);

        _UNISWAP_V2_ROUTER.call(
            abi.encodeWithSignature(
                "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)",
                _USDC_ADDRESS,
                address(cve),
                100000e6,
                100e18,
                10000e6,
                10e18,
                address(this),
                block.timestamp
            )
        );

        _createLock();

        // Select forked Ethereum
        vm.selectFork(srcForkId);

        _initMainVariables();

        _prepareCVE(address(this), 100e18);

        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = address(messagingHubs[42161]);
        config.votingHub = address(votingHubs[42161]);
        config.cveAddress = address(cves[42161]);
        config.feeTokenAddress = _USDC_ADDRESSES[42161];
        config.crosschainRelayer = makeAddr("Wormhole Relayer");

        // Support chainId 42161.
        centralRegistry.addChain(42161, config);
        _createLock();

        _recordEpochRewards(1, 1e6 * _ONE);
        _skipEpochDuration(1);
    }

    function testMultiSwap() public {
        // add harvester
        centralRegistry.addHarvestPermissions(address(this));
        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );
        chainlinkEthUsd.updateAnswer(2500e8);
        chainlinkUsdcUsd.updateAnswer(1e8);
        _refreshMockFeeds();

        // deal WETH (assume it's from cTokens)
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = _WETH_ADDRESS;
        feeManager.addRewardTokens(rewardTokens);
        _prepareWETH(address(feeManager), 1 ether);

        // multiswap
        SwapperLib.Swap[] memory swapActions = new SwapperLib.Swap[](1);
        address[] memory multiSwapPath = new address[](2);
        multiSwapPath[0] = _WETH_ADDRESS;
        multiSwapPath[1] = _USDC_ADDRESS;
        swapActions[0].inputToken = _WETH_ADDRESS;
        swapActions[0].outputToken = _USDC_ADDRESS;
        swapActions[0].target = _UNISWAP_V2_ROUTER;
        swapActions[0].inputAmount = 1 ether;
        swapActions[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            1 ether,
            0,
            multiSwapPath,
            address(feeManager),
            block.timestamp
        );
        swapActions[0].slippage = 10e16;
        feeManager.multiSwap(abi.encode(swapActions), rewardTokens);

        // bridge...
        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            address(messagingHubs[42161]),
            abi.encode(_ONE)
        );
        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryLockPoints()")
        );

        deal(address(messagingHub), _ONE);

        uint256 compoundingFee = (100e6 *
            centralRegistry.protocolCompoundFee()) /
            centralRegistry.protocolHarvestFee();
        uint256 epochRewardsPerPoint = ((100e6 - compoundingFee) *
            WAD_SQUARED) / (_ONE * 2);

        assertEq(usdc.balanceOf(address(messagingHub)), 0);
        assertEq(usdc.balanceOf(address(this)), 0);

        vm.recordLogs();

        messagingHub.executeEpoch(response, signatures, 100e6, 0);

        assertEq(usdc.balanceOf(address(messagingHub)), 0);
        assertEq(usdc.balanceOf(address(this)), compoundingFee);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Select forked Arbitrum
        vm.selectFork(dstForkId);

        _initMainVariables();

        assertEq(usdc.balanceOf(address(messagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeManager)), 0);

        vm.prank(address(messagingHub));
        rewardManager.recordEpochRewards(1e6 * _ONE);

        uint256 nextEpoch = rewardManager.nextEpochToDeliver();
        uint256 hypotheticalRewardsClaim = rewardManager
            .hypotheticalRewardsClaim(user1);

        assertTrue(rewardManager.hasRewardsToClaim(user1));

        // Simulate wormhole cross-chain messaging
        wormholeHelper.helpWithCctpAndWormhole(
            2,
            dstForkId,
            address(messagingHub),
            _CROSSCHAIN_RELAYER,
            _CIRCLE_MESSAGE_TRANSMITTER,
            logs
        );

        assertEq(
            rewardManager.epochRewardsPerPoint(nextEpoch),
            epochRewardsPerPoint
        );
        assertEq(rewardManager.nextEpochToDeliver(), nextEpoch + 1);

        uint256 rewards = hypotheticalRewardsClaim +
            epochRewardsPerPoint /
            WAD;

        assertEq(rewardManager.hypotheticalRewardsClaim(user1), rewards);

        SwapperLib.Swap memory swapAction;
        address[] memory path = new address[](2);

        path[0] = _USDC_ADDRESS;
        path[1] = address(cve);

        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.outputToken = address(cve);
        swapAction.target = _UNISWAP_V2_ROUTER;
        swapAction.inputAmount = rewards;
        swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            rewards,
            0,
            path,
            address(rewardManager),
            block.timestamp
        );

        uint256[] memory amountsOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(rewards, path);
        uint256 baseRewardBalance = usdc.balanceOf(address(rewardManager));
        uint256 desiredTokenBalance = cve.balanceOf(user1);

        vm.prank(user1);
        rewardManager.claimRewards(action, abi.encode(swapAction), 0);

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - amountsOut[0]
        );

        assertEq(cve.balanceOf(user1), desiredTokenBalance + amountsOut[1]);
    }

    function testExecuteOTC() public {

        // Set oracle prices using the mock feeds
        mockWethFeed.setMockAnswer(2500e8);
        mockUsdcFeed.setMockAnswer(1e8);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);

        // deal WETH (assume it's from cTokens)
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = _WETH_ADDRESS;
        feeManager.addRewardTokens(rewardTokens);
        feeManager.setEarmarked(_WETH_ADDRESS, true);
        _prepareWETH(address(feeManager), 1 ether);

        // multiswap
        _prepareUSDC(address(this), 2500e8);
        usdc.approve(address(feeManager), 2500e8);

        // Eth spoofed as $2500, USDC spoofed as $1
        feeManager.executeOTC(
            _WETH_ADDRESS,
            1 ether,
            2500e6,
            1e16,
            block.timestamp + 300
        ); // 5 min deadline.

        // bridge...
        PerChainData[] memory perChainData = new PerChainData[](1);
        perChainData[0] = PerChainData(
            23,
            block.number,
            uint64(block.timestamp * 1000000),
            address(messagingHubs[42161]),
            abi.encode(_ONE)
        );
        _prepareResponseAndSignatures(
            perChainData,
            abi.encodeWithSignature("queryLockPoints()")
        );

        deal(address(messagingHub), _ONE);

        uint256 compoundingFee = (100e6 *
            centralRegistry.protocolCompoundFee()) /
            centralRegistry.protocolHarvestFee();
        uint256 epochRewardsPerPoint = ((100e6 - compoundingFee) *
            WAD_SQUARED) / (_ONE * 2);

        assertEq(usdc.balanceOf(address(messagingHub)), 0);
        uint256 balanceBefore = usdc.balanceOf(address(this));

        vm.recordLogs();

        messagingHub.executeEpoch(response, signatures, 100e6, 0);

        assertEq(usdc.balanceOf(address(messagingHub)), 0);
        assertEq(
            usdc.balanceOf(address(this)),
            balanceBefore + compoundingFee
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Select forked Arbitrum
        vm.selectFork(dstForkId);

        _initMainVariables();

        assertEq(usdc.balanceOf(address(messagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeManager)), 0);

        vm.prank(address(messagingHub));
        rewardManager.recordEpochRewards(1e6 * _ONE);

        uint256 nextEpoch = rewardManager.nextEpochToDeliver();
        uint256 hypotheticalRewardsClaim = rewardManager
            .hypotheticalRewardsClaim(user1);

        assertTrue(rewardManager.hasRewardsToClaim(user1));

        // Simulate wormhole cross-chain messaging
        // Simulate wormhole cross-chain messaging
        wormholeHelper.helpWithCctpAndWormhole(
            2,
            dstForkId,
            address(messagingHub),
            _CROSSCHAIN_RELAYER,
            _CIRCLE_MESSAGE_TRANSMITTER,
            logs
        );

        assertEq(
            rewardManager.epochRewardsPerPoint(nextEpoch),
            epochRewardsPerPoint
        );
        assertEq(rewardManager.nextEpochToDeliver(), nextEpoch + 1);

        uint256 rewards = hypotheticalRewardsClaim +
            epochRewardsPerPoint /
            WAD;

        assertEq(rewardManager.hypotheticalRewardsClaim(user1), rewards);

        SwapperLib.Swap memory swapAction;
        address[] memory path = new address[](2);

        path[0] = _USDC_ADDRESS;
        path[1] = address(cve);

        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.outputToken = address(cve);
        swapAction.target = _UNISWAP_V2_ROUTER;
        swapAction.inputAmount = rewards;
        swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            rewards,
            0,
            path,
            address(rewardManager),
            block.timestamp
        );

        uint256[] memory amountsOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(rewards, path);
        uint256 baseRewardBalance = usdc.balanceOf(address(rewardManager));
        uint256 desiredTokenBalance = cve.balanceOf(user1);

        vm.prank(user1);
        rewardManager.claimRewards(action, abi.encode(swapAction), 0);

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - amountsOut[0]
        );

        assertEq(cve.balanceOf(user1), desiredTokenBalance + amountsOut[1]);
    }

    function _createLock() internal {
        _skipRestrictionDuration();

        vm.startPrank(user1);

        _prepareCVE(user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(_ONE, false, action, "", 0);

        vm.stopPrank();
    }
}
