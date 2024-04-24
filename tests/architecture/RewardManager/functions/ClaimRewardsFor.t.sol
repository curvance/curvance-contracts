// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCallDataChecker } from "contracts/mocks/MockCallDataChecker.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";

contract ClaimRewardsForTest is TestBaseRewardManager {
    address internal constant _UNISWAP_V2_ROUTER =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    RewardsData public rewardsData = RewardsData(true, false, false, false);
    SwapperLib.Swap public swapData;
    address[] public path;

    function setUp() public override {
        super.setUp();

        path.push(_USDC_ADDRESS);
        path.push(address(cve));

        swapData.inputToken = _USDC_ADDRESS;
        swapData.inputAmount = 100e6;
        swapData.outputToken = address(cve);
        swapData.target = _UNISWAP_V2_ROUTER;
        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            100e6,
            0,
            path,
            address(rewardManager),
            block.timestamp
        );

        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCallDataChecker(_UNISWAP_V2_ROUTER))
        );

        deal(_USDC_ADDRESS, address(rewardManager), 10000e6);

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
    }

    function test_claimRewardsFor_fail_whenCallerIsNotVeCVE() public {
        uint256 epoch = rewardManager.epochsToClaim(user1);

        vm.expectRevert(RewardManager.RewardManager__Unauthorized.selector);
        rewardManager.claimRewardsFor(
            user1,
            epoch,
            rewardsData,
            abi.encode(swapData),
            0
        );
    }

    function test_claimRewardsFor_success_fuzzed(uint256 amount) public {
        vm.assume(amount > 1e18 && amount <= 100e18);

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(centralRegistry.protocolMessagingHub());
            rewardManager.recordEpochRewards(_ONE);
        }

        skip(veCVE.RESTRICTION_DURATION() + 1);

        vm.startPrank(user1);

        deal(address(cve), user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(amount, false, rewardsData, "0x", 0);

        vm.stopPrank();

        vm.prank(address(veCVE));
        rewardManager.updateUserClaimIndex(user1, 1);

        assertTrue(rewardManager.hasRewardsToClaim(user1));

        deal(_USDC_ADDRESS, address(rewardManager), amount);

        swapData.inputAmount = amount;
        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amount,
            0,
            path,
            address(rewardManager),
            block.timestamp
        );

        uint256[] memory amountsOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(amount, path);
        uint256 baseRewardBalance = usdc.balanceOf(address(rewardManager));
        uint256 desiredTokenBalance = cve.balanceOf(user1);
        uint256 epoch = rewardManager.epochsToClaim(user1);

        assertEq(rewardManager.currentEpoch(block.timestamp) + 1, epoch);

        vm.prank(address(veCVE));
        rewardManager.claimRewardsFor(
            user1,
            epoch,
            rewardsData,
            abi.encode(swapData),
            0
        );

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - amountsOut[0]
        );
        assertEq(cve.balanceOf(user1), desiredTokenBalance + amountsOut[1]);
    }
}
