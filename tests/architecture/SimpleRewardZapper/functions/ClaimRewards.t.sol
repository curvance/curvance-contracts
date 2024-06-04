// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseSimpleRewardZapper } from "../TestBaseSimpleRewardZapper.sol";

import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { SimpleRewardZapper } from "contracts/architecture/utils/SimpleRewardZapper.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCallDataChecker } from "contracts/mocks/MockCallDataChecker.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";

contract ClaimRewardsTest is TestBaseSimpleRewardZapper {
    RewardsData public rewardsData = RewardsData(false, false, false, false);
    SwapperLib.Swap public swapData;
    address[] public path;

    function setUp() public override {
        super.setUp();

        path.push(_USDC_ADDRESS);
        path.push(_WETH_ADDRESS);

        swapData.inputToken = _USDC_ADDRESS;
        swapData.inputAmount = 1e18;
        swapData.outputToken = _WETH_ADDRESS;
        swapData.target = _UNISWAP_V2_ROUTER;
        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            1e18,
            0,
            path,
            address(rewardManager),
            block.timestamp
        );

        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCallDataChecker(_UNISWAP_V2_ROUTER))
        );

        deal(_USDC_ADDRESS, address(rewardManager), 1e18);
    }

    function test_claimRewards_fail_whenNoEpochRewardsToClaim() public {
        simpleRewardZapper.addAuthorizedOutputToken(_WETH_ADDRESS);

        vm.prank(address(rewardManager.veCVE()));
        rewardManager.updateUserClaimIndex(user1, 1);

        vm.prank(user1);

        vm.expectRevert(RewardManager.RewardManager__NoEpochRewards.selector);

        rewardManager.claimRewards(rewardsData, abi.encode(swapData), 0);
    }

    function test_claimRewards_success_fuzzed(uint256 amount) public {
        vm.assume(amount > 1e18 && amount <= 100e18);

        simpleRewardZapper.addAuthorizedOutputToken(_WETH_ADDRESS);

        _skipRestrictionDuration();

        vm.startPrank(user1);

        deal(address(cve), user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(amount, false, rewardsData, "0x", 0);

        vm.stopPrank();

        vm.prank(address(rewardManager.veCVE()));
        rewardManager.updateUserClaimIndex(user1, 1);

        uint256 rewards = amount /= 1e12;

        _recordEpochRewards(2, 1e6 * _ONE);

        deal(_USDC_ADDRESS, address(rewardManager), rewards);

        swapData.inputAmount = rewards;
        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            rewards,
            0,
            path,
            address(simpleRewardZapper),
            block.timestamp
        );

        uint256[] memory amountsOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(rewards, path);
        uint256 baseRewardBalance = usdc.balanceOf(address(rewardManager));
        uint256 desiredTokenBalance = IERC20(_WETH_ADDRESS).balanceOf(user1);

        vm.prank(user1);
        rewardManager.setDelegateApproval(address(simpleRewardZapper), true);

        vm.prank(user1);
        simpleRewardZapper.claimAndSwap(swapData, user1);

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - amountsOut[0]
        );
        assertEq(
            IERC20(_WETH_ADDRESS).balanceOf(user1),
            desiredTokenBalance + amountsOut[1]
        );
    }
}
