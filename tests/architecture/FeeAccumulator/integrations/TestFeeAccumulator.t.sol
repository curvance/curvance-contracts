// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseFeeAccumulator } from "../TestBaseFeeAccumulator.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";
import { WormholeMock } from "tests/utils/WormholeMock.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCallDataChecker } from "contracts/mocks/MockCallDataChecker.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";
import { WormholeHelper } from "@pigeon/src/wormhole/automatic-relayer/WormholeHelper.sol";
import { Vm } from "forge-std/Vm.sol";

contract TestFeeAccumulator is TestBaseFeeAccumulator {
    uint256 public srcForkId;
    uint256 public dstForkId;
    WormholeHelper public wormholeHelper;
    RewardsData public rewardsData = RewardsData(true, false, false, false);

    function setUp() public override {
        // Fork Ethereum as source chain and select it
        srcForkId = _fork(19140000);

        _WORMHOLE_CORES[block.chainid] = address(new WormholeMock());

        // Deploy contracts on forked Ethereum
        _init();

        // Fork Arbitrum as destination chain and select it
        dstForkId = _fork("ETH_NODE_URI_ARBITRUM", 180000000);

        wormholeHelper = new WormholeHelper();

        // Deploy contracts on forked Arbitrum
        _deployBaseContracts();

        centralRegistry.setMessageTransmitter(_CIRCLE_MESSAGE_TRANSMITTER);
        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCallDataChecker(_UNISWAP_V2_ROUTER))
        );
        centralRegistry.addChainSupport(
            address(protocolMessagingHubs[1]),
            address(cves[1]),
            _USDC_ADDRESSES[1],
            1,
            2,
            makeAddr("Wormhole Relayer"),
            0
        );

        deal(_USDC_ADDRESS, address(rewardManager), 100000e6);
        deal(_USDC_ADDRESS, address(this), 100000e6);
        deal(address(cve), address(this), 100e18);

        IERC20(_USDC_ADDRESS).approve(_UNISWAP_V2_ROUTER, 100000e6);
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

        deal(address(cve), address(this), 100e18);

        centralRegistry.addChainSupport(
            address(protocolMessagingHubs[42161]),
            address(cves[42161]),
            _USDC_ADDRESSES[42161],
            42161,
            23,
            makeAddr("Wormhole Relayer"),
            3
        );

        _createLock();

        _skipEpochDuration(3);
    }

    function testMultiSwap() public {
        // add harvester
        centralRegistry.addHarvester(address(this));
        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCallDataChecker(_UNISWAP_V2_ROUTER))
        );
        chainlinkEthUsd.updateAnswer(2500e8);
        chainlinkUsdcUsd.updateAnswer(1e8);

        // deal WETH (assume it's from ctokens)
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = _WETH_ADDRESS;
        feeAccumulator.addRewardTokens(rewardTokens);
        deal(_WETH_ADDRESS, address(feeAccumulator), 1 ether);

        // multiswap
        SwapperLib.Swap[] memory multiSwapData = new SwapperLib.Swap[](1);
        address[] memory multiSwapPath = new address[](2);
        multiSwapPath[0] = _WETH_ADDRESS;
        multiSwapPath[1] = _USDC_ADDRESS;
        multiSwapData[0].inputToken = _WETH_ADDRESS;
        multiSwapData[0].outputToken = _USDC_ADDRESS;
        multiSwapData[0].target = _UNISWAP_V2_ROUTER;
        multiSwapData[0].inputAmount = 1 ether;
        multiSwapData[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            1 ether,
            0,
            multiSwapPath,
            address(feeAccumulator),
            block.timestamp
        );
        multiSwapData[0].slippage = 10e16;
        feeAccumulator.multiSwap(abi.encode(multiSwapData), rewardTokens);

        // bridge...
        _prepareResponseAndSignatures(
            abi.encode(_ONE),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            address(protocolMessagingHubs[42161]),
            abi.encodeWithSignature("queryLockPoints()")
        );

        deal(address(protocolMessagingHub), _ONE);

        uint256 compoundingFee = (100e6 *
            centralRegistry.protocolCompoundFee()) /
            centralRegistry.protocolYieldFee();
        uint256 epochRewardsPerPoint = ((100e6 - compoundingFee) * WAD) / 2;

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(this)), 0);

        vm.recordLogs();

        protocolMessagingHub.executeEpoch(
            response,
            signatures,
            100e6,
            250_000
        );

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(this)), compoundingFee);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Select forked Arbitrum
        vm.selectFork(dstForkId);

        _initMainVariables();

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeAccumulator)), 0);

        vm.prank(address(protocolMessagingHub));
        rewardManager.recordEpochRewards(1e6 * _ONE);

        uint256 nextEpoch = rewardManager.nextEpochToDeliver();
        uint256 hypotheticalRewardsClaim = rewardManager
            .hypotheticalRewardsClaim(user1);

        assertTrue(rewardManager.hasRewardsToClaim(user1));

        // Simulate wormhole cross-chain messaging
        wormholeHelper.helpWithCctpAndWormhole(
            2,
            dstForkId,
            address(protocolMessagingHub),
            _WORMHOLE_RELAYER,
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

        SwapperLib.Swap memory swapData;
        address[] memory path = new address[](2);

        path[0] = _USDC_ADDRESS;
        path[1] = address(cve);

        swapData.inputToken = _USDC_ADDRESS;
        swapData.outputToken = address(cve);
        swapData.target = _UNISWAP_V2_ROUTER;
        swapData.inputAmount = rewards;
        swapData.call = abi.encodeWithSignature(
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
        rewardManager.claimRewards(rewardsData, abi.encode(swapData), 0);

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - amountsOut[0]
        );

        assertEq(cve.balanceOf(user1), desiredTokenBalance + amountsOut[1]);
    }

    function testExecuteOTC() public {
        // add harvester
        chainlinkEthUsd.updateAnswer(2500e8);
        chainlinkUsdcUsd.updateAnswer(1e8);

        // deal WETH (assume it's from ctokens)
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = _WETH_ADDRESS;
        feeAccumulator.addRewardTokens(rewardTokens);
        feeAccumulator.setEarmarked(_WETH_ADDRESS, true);
        deal(_WETH_ADDRESS, address(feeAccumulator), 1 ether);

        // multiswap
        deal(_USDC_ADDRESS, address(this), 2500e8);
        IERC20(_USDC_ADDRESS).approve(address(feeAccumulator), 2500e8);
        feeAccumulator.executeOTC(_WETH_ADDRESS, 1 ether);

        // bridge...
        _prepareResponseAndSignatures(
            abi.encode(_ONE),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            address(protocolMessagingHubs[42161]),
            abi.encodeWithSignature("queryLockPoints()")
        );

        deal(address(protocolMessagingHub), _ONE);

        uint256 compoundingFee = (100e6 *
            centralRegistry.protocolCompoundFee()) /
            centralRegistry.protocolYieldFee();
        uint256 epochRewardsPerPoint = ((100e6 - compoundingFee) * WAD) / 2;

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        uint256 balanceBefore = usdc.balanceOf(address(this));

        vm.recordLogs();

        protocolMessagingHub.executeEpoch(
            response,
            signatures,
            100e6,
            250_000
        );

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(
            usdc.balanceOf(address(this)),
            balanceBefore + compoundingFee
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Select forked Arbitrum
        vm.selectFork(dstForkId);

        _initMainVariables();

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeAccumulator)), 0);

        vm.prank(centralRegistry.protocolMessagingHub());
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
            address(protocolMessagingHub),
            _WORMHOLE_RELAYER,
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

        SwapperLib.Swap memory swapData;
        address[] memory path = new address[](2);

        path[0] = _USDC_ADDRESS;
        path[1] = address(cve);

        swapData.inputToken = _USDC_ADDRESS;
        swapData.outputToken = address(cve);
        swapData.target = _UNISWAP_V2_ROUTER;
        swapData.inputAmount = rewards;
        swapData.call = abi.encodeWithSignature(
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
        rewardManager.claimRewards(rewardsData, abi.encode(swapData), 0);

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - amountsOut[0]
        );

        assertEq(cve.balanceOf(user1), desiredTokenBalance + amountsOut[1]);
    }

    function _createLock() internal {
        _skipRestrictionDuration();

        vm.startPrank(user1);

        deal(address(cve), user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(_ONE, false, rewardsData, "0x", 0);

        vm.stopPrank();
    }
}
