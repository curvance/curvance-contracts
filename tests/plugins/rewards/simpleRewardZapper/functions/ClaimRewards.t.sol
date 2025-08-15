// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ClaimAction } from "contracts/interfaces/IRewardManager.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";

import { TestBaseSimpleRewardZapper, BaseZapper, SimpleRewardZapper } from "../TestBaseSimpleRewardZapper.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

contract ClaimRewardsTest is TestBaseSimpleRewardZapper {
    ClaimAction public action = ClaimAction(false, false, false, false);
    SwapperLib.Swap public swapAction;
    address[] public path;

    function setUp() public override {
        super.setUp();

        path.push(_USDC_ADDRESS);
        path.push(_WETH_ADDRESS);

        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 1e18;
        swapAction.outputToken = _WETH_ADDRESS;
        swapAction.target = _UNISWAP_V2_ROUTER;
        swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            1e18,
            0,
            path,
            address(rewardManager),
            block.timestamp
        );

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        _prepareUSDC(address(rewardManager), 1e18);
    }

    function test_claimRewards_fail_whenNoEpochRewardsToClaim() public {
        simpleRewardZapper.addAuthorizedOutputToken(_WETH_ADDRESS);

        vm.prank(address(centralRegistry.veCVE()));
        rewardManager.updateUserClaimIndex(user1, 1);

        vm.prank(user1);

        vm.expectRevert(RewardManager.RewardManager__NoEpochRewards.selector);

        rewardManager.claimRewards(action, abi.encode(swapAction), 0);
    }

    function test_claimRewards_success_fuzzed(uint256 amount) public {
        vm.assume(amount > 1e18 && amount <= 100e18);

        simpleRewardZapper.addAuthorizedOutputToken(_WETH_ADDRESS);

        _skipRestrictionDuration();

        vm.startPrank(user1);

        _prepareCVE(user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(amount, false, action, "", 0);

        vm.stopPrank();

        vm.prank(address(centralRegistry.veCVE()));
        rewardManager.updateUserClaimIndex(user1, 1);

        uint256 rewards = amount /= 1e12;

        _recordEpochRewards(2, 1e6 * _ONE);

        _prepareUSDC(address(rewardManager), rewards);

        swapAction.inputAmount = rewards;
        swapAction.call = abi.encodeWithSignature(
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
        uint256 desiredTokenBalance = weth.balanceOf(user1);

        vm.prank(user1);
        rewardManager.setDelegateApproval(address(simpleRewardZapper), true);

        vm.prank(user1);
        simpleRewardZapper.claimAndSwap(swapAction, user1);

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - amountsOut[0]
        );
        assertEq(weth.balanceOf(user1), desiredTokenBalance + amountsOut[1]);
    }
}
