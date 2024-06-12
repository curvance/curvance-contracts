// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseProtocolMessagingHub } from "../TestBaseProtocolMessagingHub.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { MockCallDataChecker } from "contracts/mocks/MockCallDataChecker.sol";
import { WormholeMock } from "tests/utils/WormholeMock.sol";
import { WormholeHelper } from "@pigeon/src/wormhole/automatic-relayer/WormholeHelper.sol";
import { Vm } from "forge-std/Vm.sol";
import { stdStorage, StdStorage } from "forge-std/Test.sol";

contract TestProtocolMessagingHub is TestBaseProtocolMessagingHub {
    using stdStorage for StdStorage;

    uint256 public srcForkId;
    uint256 public dstForkId;
    WormholeHelper public wormholeHelper;
    RewardsData public rewardsData = RewardsData(true, false, false, false);
    VeCVE.BridgeData public bridgeData = VeCVE.BridgeData(42161, 0, false);

    function setUp() public override {
        // Fork Ethereum as source chain and select it
        srcForkId = _fork(19140000);

        _WORMHOLE_CORES[block.chainid] = address(new WormholeMock());

        // Deploy contracts on forked Ethereum
        _init();

        // Fork Arbitrum as destination chain and select it
        dstForkId = _fork("ETH_NODE_URI_ARBITRUM", 213946165);

        wormholeHelper = new WormholeHelper();

        // Deploy contracts on forked Arbitrum
        _deployBaseContracts();

        deal(_USDC_ADDRESS, address(rewardManager), 100000e6);

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
            _WORMHOLE_RELAYERS[1],
            0
        );

        _addLiquidityToUniswap();

        // Select forked Ethereum
        vm.selectFork(srcForkId);

        _initMainVariables();

        deal(_USDC_ADDRESS, address(rewardManager), 100000e6);
        deal(address(protocolMessagingHub), _ONE);
        deal(address(cve), address(this), 100e18);

        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCallDataChecker(_UNISWAP_V2_ROUTER))
        );
        centralRegistry.addChainSupport(
            address(protocolMessagingHubs[42161]),
            address(cves[42161]),
            _USDC_ADDRESSES[42161],
            42161,
            23,
            _WORMHOLE_RELAYERS[42161],
            3
        );

        _addLiquidityToUniswap();
    }

    function test_executeEpoch_receiveWormholeMessages_claimReward_success()
        public
    {
        _createLock();

        _skipEpochDuration(3);

        _prepareResponseAndSignatures(
            abi.encode(_ONE),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            address(protocolMessagingHubs[42161]),
            abi.encodeWithSignature("queryLockPoints()")
        );

        deal(_USDC_ADDRESS, address(feeAccumulator), 100e6);

        uint256 compoundingFee = (100e6 *
            centralRegistry.protocolCompoundFee()) /
            centralRegistry.protocolHarvestFee();
        uint256 epochRewardsPerPoint = ((100e6 - compoundingFee) * WAD) / 2;

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeAccumulator)), 100e6);
        assertEq(usdc.balanceOf(address(this)), 0);

        vm.recordLogs();

        protocolMessagingHub.executeEpoch(
            response,
            signatures,
            100e6,
            250_000
        );

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeAccumulator)), 0);
        assertEq(usdc.balanceOf(address(this)), compoundingFee);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Select forked Arbitrum
        vm.selectFork(dstForkId);

        _initMainVariables();

        _createLock();

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeAccumulator)), 0);

        _recordEpochRewards(1, 1e6 * _ONE);

        uint256 nextEpoch = rewardManager.nextEpochToDeliver();
        uint256 hypotheticalRewardsClaim = rewardManager
            .hypotheticalRewardsClaim(user1);

        assertTrue(rewardManager.hasRewardsToClaim(user1));

        // Simulate wormhole cross-chain messaging with payloadType 3
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
            _ONE;

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

    function test_executeOTC_sendFees_success() public {
        feeAccumulator.setEarmarked(_WETH_ADDRESS, true);

        deal(_USDC_ADDRESS, address(this), 10000e6);
        deal(_WETH_ADDRESS, address(feeAccumulator), _ONE);

        assertEq(IERC20(_WETH_ADDRESS).balanceOf(address(this)), 0);
        assertEq(usdc.balanceOf(address(centralRegistry)), 0);

        usdc.approve(address(feeAccumulator), 10000e6);

        feeAccumulator.executeOTC(_WETH_ADDRESS, _ONE);

        assertLt(usdc.balanceOf(address(this)), 10000e6);
        assertEq(IERC20(_WETH_ADDRESS).balanceOf(address(feeAccumulator)), 0);
        assertEq(IERC20(_WETH_ADDRESS).balanceOf(address(this)), _ONE);

        uint256 daoBalance = usdc.balanceOf(address(this));
        uint256 usdcBalance = usdc.balanceOf(address(feeAccumulator));
        uint256 usdcDaoBalance = usdc.balanceOf(centralRegistry.daoAddress());

        vm.recordLogs();

        protocolMessagingHub.sendFees(42161, 1000e6, 250_000);

        uint256 compoundingFee = (1000e6 *
            centralRegistry.protocolCompoundFee()) /
            centralRegistry.protocolHarvestFee();
        uint256 pullAmount = 1000e6 - compoundingFee;

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(this)), daoBalance + compoundingFee);
        assertEq(
            usdc.balanceOf(address(feeAccumulator)),
            usdcBalance - 1000e6
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Select forked Arbitrum
        vm.selectFork(dstForkId);

        _initMainVariables();

        rewardManager.notifyShutdown();

        deal(_USDC_ADDRESS, address(protocolMessagingHub), pullAmount);

        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), 0);

        // Simulate wormhole cross-chain messaging with payloadType 1
        wormholeHelper.helpWithCctpAndWormhole(
            2,
            dstForkId,
            address(protocolMessagingHub),
            _WORMHOLE_RELAYER,
            _CIRCLE_MESSAGE_TRANSMITTER,
            logs
        );

        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), pullAmount);
    }

    function test_veCVE_bridgeLock_success() public {
        _createLock();

        deal(user1, _ONE);

        uint256 messageFee = protocolMessagingHub.quoteMessageFee(
            42161,
            false,
            0
        );

        centralRegistry.setEarlyUnlockPenaltyMultiplier(3000);

        uint256 veCVEBalance = veCVE.balanceOf(user1);
        uint256 cveTotalSupply = cve.totalSupply();

        SwapperLib.Swap memory swapData;
        address[] memory path = new address[](2);

        path[0] = _USDC_ADDRESS;
        path[1] = address(cve);

        swapData.inputToken = _USDC_ADDRESS;
        swapData.outputToken = address(cve);
        swapData.target = _UNISWAP_V2_ROUTER;
        swapData.inputAmount = 200e6;
        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            200e6,
            0,
            path,
            address(rewardManager),
            block.timestamp
        );

        vm.recordLogs();

        vm.prank(user1);
        veCVE.bridgeLock{ value: messageFee }(
            0,
            bridgeData,
            rewardsData,
            abi.encode(swapData),
            0
        );

        assertEq(veCVE.balanceOf(user1), 0);
        assertEq(cve.totalSupply(), cveTotalSupply - veCVEBalance);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Select forked Arbitrum
        vm.selectFork(dstForkId);

        _initMainVariables();

        centralRegistry.addLockingPermissions(address(protocolMessagingHub));

        _skipRestrictionDuration();

        (uint256[] memory lockAmounts, uint256[] memory lockTimestamps) = veCVE
            .queryUserLocks(user1);

        assertEq(lockAmounts.length, 0);
        assertEq(lockTimestamps.length, 0);

        uint256 timestamp = block.timestamp;

        // Simulate wormhole cross-chain messaging with payloadType 4
        wormholeHelper.help(2, dstForkId, _WORMHOLE_RELAYER, logs);

        (lockAmounts, lockTimestamps) = veCVE.queryUserLocks(user1);
        (, uint40 unlockTime) = veCVE.userLocks(user1, 0);

        assertEq(lockAmounts.length, 1);
        assertEq(lockTimestamps.length, 1);
        assertEq(lockAmounts[0], _ONE);
        assertEq(lockTimestamps[0], unlockTime);
        assertEq(
            unlockTime,
            veCVE.genesisEpoch() +
                (veCVE.currentEpoch(timestamp) * veCVE.EPOCH_DURATION()) +
                veCVE.LOCK_DURATION()
        );

        assertEq(veCVE.chainPoints(), _ONE);
        assertEq(veCVE.userPoints(user1), _ONE);
        assertEq(
            veCVE.chainUnlocksByEpoch(veCVE.currentEpoch(unlockTime)),
            _ONE
        );
        assertEq(
            veCVE.userUnlocksByEpoch(user1, veCVE.currentEpoch(unlockTime)),
            _ONE
        );
    }

    function test_cve_bridge_success() public {
        deal(user1, _ONE);
        deal(address(cve), user1, _ONE);

        uint256 messageFee = protocolMessagingHub.quoteMessageFee(
            42161,
            false,
            0
        );

        vm.recordLogs();

        vm.prank(user1);
        cve.bridge{ value: messageFee }(user1, 42161, _ONE, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(cve.balanceOf(user1), 0);

        // Select forked Arbitrum
        vm.selectFork(dstForkId);

        _initMainVariables();

        assertEq(cve.balanceOf(address(user1)), 0);

        wormholeHelper.help(2, dstForkId, _WORMHOLE_RELAYER, logs);

        assertEq(cve.balanceOf(address(user1)), _ONE);
    }

    function _createLock() internal {
        _skipRestrictionDuration();

        vm.startPrank(user1);

        deal(address(cve), user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(_ONE, false, rewardsData, "0x", 0);

        vm.stopPrank();
    }

    function _addLiquidityToUniswap() internal {
        deal(_USDC_ADDRESS, user2, 1000000e6);
        deal(address(cve), user2, 1000e18);

        vm.startPrank(user2);

        IERC20(_USDC_ADDRESS).approve(_UNISWAP_V2_ROUTER, 1000000e6);
        cve.approve(_UNISWAP_V2_ROUTER, 1000e18);

        _UNISWAP_V2_ROUTER.call(
            abi.encodeWithSignature(
                "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)",
                _USDC_ADDRESS,
                address(cve),
                1000000e6,
                1000e18,
                100000e6,
                100e18,
                address(this),
                block.timestamp
            )
        );

        vm.stopPrank();
    }
}
