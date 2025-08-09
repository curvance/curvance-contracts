// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";

contract ClaimRewardsTest is TestBaseRewardManager {
    RewardsData public rewardsData = RewardsData(true, false, false, false);
    SwapperLib.Swap public swapAction;
    address[] public path;

    function setUp() public override {
        super.setUp();

        path.push(_USDC_ADDRESS);
        path.push(address(cve));

        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 100e6;
        swapAction.outputToken = address(cve);
        swapAction.target = _UNISWAP_V2_ROUTER;
        swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            100e6,
            0,
            path,
            address(rewardManager),
            block.timestamp
        );

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        _prepareUSDC(address(rewardManager), 10000e6);

        _prepareUSDC(address(this), 10000e6);
        _prepareCVE(address(this), 1000000e18);

        usdc.approve(_UNISWAP_V2_ROUTER, 10000e6);
        cve.approve(_UNISWAP_V2_ROUTER, 1000000e18);

        _UNISWAP_V2_ROUTER.call(
            abi.encodeWithSignature(
                "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)",
                _USDC_ADDRESS,
                address(cve),
                10000e6,
                1000000e18,
                10000e6,
                1000000e18,
                address(this),
                block.timestamp
            )
        );
    }

    function test_claimRewards_fail_whenNoEpochRewardsToClaim() public {
        vm.prank(address(veCVE));
        rewardManager.updateUserClaimIndex(user1, 1);

        vm.prank(user1);

        vm.expectRevert(RewardManager.RewardManager__NoEpochRewards.selector);
        rewardManager.claimRewards(rewardsData, abi.encode(swapAction), 0);
    }

    function test_claimRewards_fail_whenSwapActionIsInvalid() public {
        _skipRestrictionDuration();

        vm.startPrank(user1);

        _prepareCVE(user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(100e18, false, rewardsData, "", 0);

        vm.stopPrank();

        vm.prank(address(veCVE));
        rewardManager.updateUserClaimIndex(user1, 1);

        swapAction.inputToken = _DAI_ADDRESS;

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        vm.prank(user1);

        vm.expectRevert(
            RewardManager.RewardManager__SwapActionIsInvalid.selector
        );
        rewardManager.claimRewards(rewardsData, abi.encode(swapAction), 0);
    }

    function test_claimRewards_success_fuzzed(
        uint256 amount,
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) public {
        centralRegistry.addLockingPermissions(address(rewardManager));

        rewardsData = RewardsData(
            true,
            shouldLock,
            isFreshLock,
            isFreshLockContinuous
        );

        vm.assume(amount > 1e18 && amount <= 100e18);

        assertFalse(rewardManager.hasRewardsToClaim(user1));
        assertEq(rewardManager.hypotheticalRewardsClaim(user1), 0);

        _skipRestrictionDuration();

        vm.startPrank(user1);

        _prepareCVE(user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(amount, isFreshLockContinuous, rewardsData, "", 0);

        vm.stopPrank();

        vm.prank(address(veCVE));
        rewardManager.updateUserClaimIndex(user1, 1);

        uint256 rewards = isFreshLockContinuous ? amount * 2 : amount;
        rewards /= 1e12;

        _recordEpochRewards(2, 1e6 * _ONE);

        assertTrue(rewardManager.hasRewardsToClaim(user1));
        assertEq(rewardManager.hypotheticalRewardsClaim(user1), rewards);

        _prepareUSDC(address(rewardManager), rewards);

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
        rewardManager.claimRewards(rewardsData, abi.encode(swapAction), 0);

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - amountsOut[0]
        );

        if (shouldLock) {
            assertEq(cve.balanceOf(user1), desiredTokenBalance);
        } else {
            assertEq(
                cve.balanceOf(user1),
                desiredTokenBalance + amountsOut[1]
            );
        }
    }
}
