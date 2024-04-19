// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseProtocolMessagingHub } from "../TestBaseProtocolMessagingHub.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";
import { WormholeMock } from "tests/utils/WormholeMock.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { CVELocker } from "contracts/architecture/CVELocker.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCallDataChecker } from "contracts/mocks/MockCallDataChecker.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { RewardsData } from "contracts/interfaces/ICVELocker.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";

contract TestProtocolMessagingHub is TestBaseProtocolMessagingHub {
    RewardsData public rewardsData = RewardsData(true, false, false, false);
    address internal constant _UNISWAP_V2_ROUTER =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    SwapperLib.Swap public swapData;
    address[] public path;

    function setUp() public override {
        _fork(19140000);

        WormholeMock wormholeMock = new WormholeMock();
        _WORMHOLE_CORE = address(wormholeMock);

        _init();

        path.push(_USDC_ADDRESS);
        path.push(address(cve));

        swapData.inputToken = _USDC_ADDRESS;
        swapData.outputToken = address(cve);
        swapData.target = _UNISWAP_V2_ROUTER;

        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCallDataChecker(_UNISWAP_V2_ROUTER))
        );
        centralRegistry.addChainSupport(
            address(protocolMessagingHub),
            address(protocolMessagingHub),
            address(cve),
            _USDC_ADDRESS,
            42161,
            1,
            1,
            23
        );

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 42161;
        centralRegistry.updateForeignChainIds(chainIds);

        deal(_USDC_ADDRESS, address(cveLocker), 10000e6);
        deal(_USDC_ADDRESS, address(this), 10000e6);
        deal(address(cve), address(this), 100e18);

        IERC20(_USDC_ADDRESS).approve(_UNISWAP_V2_ROUTER, 10000e6);
        cve.approve(_UNISWAP_V2_ROUTER, 100e18);

        _UNISWAP_V2_ROUTER.call(
            abi.encodeWithSignature(
                "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)",
                _USDC_ADDRESS,
                address(cve),
                10000e6,
                100e18,
                10000e6,
                100e18,
                address(this),
                block.timestamp
            )
        );

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(centralRegistry.protocolMessagingHub());
            cveLocker.recordEpochRewards(_ONE);
        }

        skip(veCVE.RESTRICTION_DURATION() + 1);

        vm.startPrank(user1);

        deal(address(cve), user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(_ONE, false, rewardsData, "0x", 0);

        vm.stopPrank();

        skip(cveLocker.EPOCH_DURATION() * 3);
    }

    function test_executeEpoch_receiveWormholeMessages_claimReward_success()
        public
    {
        _prepareResponseAndSignatures(
            abi.encode(_ONE),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            address(protocolMessagingHub),
            abi.encodeWithSignature("queryLockPoints()")
        );

        deal(address(protocolMessagingHub), _ONE);
        deal(_USDC_ADDRESS, address(feeAccumulator), 100e6);

        uint256 compoundingFee = (100e6 *
            centralRegistry.protocolCompoundFee()) /
            centralRegistry.protocolHarvestFee();
        uint256 epochRewardsPerCVE = ((100e6 - compoundingFee) * WAD) / _ONE;

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeAccumulator)), 100e6);
        assertEq(usdc.balanceOf(address(centralRegistry)), 0);

        protocolMessagingHub.executeEpoch(
            response,
            signatures,
            100e6,
            250_000
        );

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeAccumulator)), 0);
        assertEq(usdc.balanceOf(address(centralRegistry)), compoundingFee);

        uint256 nextEpoch = cveLocker.nextEpochToDeliver();
        uint256 hypotheticalRewardsClaim = cveLocker.hypotheticalRewardsClaim(
            user1
        );

        assertEq(cveLocker.epochRewardsPerCVE(nextEpoch), 0);
        assertTrue(cveLocker.hasRewardsToClaim(user1));

        vm.prank(_WORMHOLE_RELAYER);
        protocolMessagingHub.receiveWormholeMessages(
            abi.encode(3, epochRewardsPerCVE),
            new bytes[](0),
            bytes32(uint256(uint160(address(protocolMessagingHub)))),
            23,
            bytes32("0x01")
        );

        assertEq(cveLocker.epochRewardsPerCVE(nextEpoch), epochRewardsPerCVE);
        assertEq(cveLocker.nextEpochToDeliver(), nextEpoch + 1);

        assertTrue(cveLocker.hasRewardsToClaim(user1));
        assertEq(
            cveLocker.hypotheticalRewardsClaim(user1),
            hypotheticalRewardsClaim + epochRewardsPerCVE
        );

        uint256 rewards = hypotheticalRewardsClaim + epochRewardsPerCVE;

        deal(_USDC_ADDRESS, address(cveLocker), rewards);

        swapData.inputAmount = rewards;
        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            rewards,
            0,
            path,
            address(cveLocker),
            block.timestamp
        );

        uint256[] memory amountsOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(rewards, path);
        uint256 baseRewardBalance = usdc.balanceOf(address(cveLocker));
        uint256 desiredTokenBalance = cve.balanceOf(user1);

        vm.prank(user1);
        cveLocker.claimRewards(rewardsData, abi.encode(swapData), 0);

        assertEq(
            usdc.balanceOf(address(cveLocker)),
            baseRewardBalance - amountsOut[0]
        );

        assertEq(cve.balanceOf(user1), desiredTokenBalance + amountsOut[1]);
    }
}
