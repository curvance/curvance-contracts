// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseRewardManager } from "../TestBaseRewardManager.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract RewardManagerRescueTokenTest is TestBaseRewardManager {
    receive() external payable {}

    function setUp() public override {
        super.setUp();

        _prepareDAI(address(rewardManager), 100e18);
        deal(address(rewardManager), 100e18);
    }

    function test_rewardManagerRescueToken_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(RewardManager.RewardManager__Unauthorized.selector);
        rewardManager.rescueToken(_DAI_ADDRESS, 100);
    }

    function test_rewardManagerRescueToken_fail_whenTokenIsRewardToken()
        public
    {
        vm.expectRevert(RewardManager.RewardManager__Unauthorized.selector);
        rewardManager.rescueToken(_USDC_ADDRESS, 100);
    }

    function test_rewardManagerRescueToken_fail_whenAmountExceedsBalance()
        public
    {
        uint256 balance = dai.balanceOf(address(rewardManager));

        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        rewardManager.rescueToken(_DAI_ADDRESS, balance + 1);
    }

    function test_rewardManagerRescueToken_success_withNativeAsset_withWithdrawAll()
        public
    {
        uint256 balance = address(rewardManager).balance;
        uint256 holding = address(this).balance;

        rewardManager.rescueToken(address(0), 0);

        assertEq(address(rewardManager).balance, 0);
        assertEq(address(this).balance, holding + balance);
    }

    function test_rewardManagerRescueToken_success_withNativeAsset_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 <= amount && amount <= 100e18);

        uint256 balance = address(rewardManager).balance;
        uint256 holding = address(this).balance;

        rewardManager.rescueToken(address(0), amount);

        uint256 withdrawalAmount = amount == 0 ? balance : amount;

        assertEq(address(rewardManager).balance, balance - withdrawalAmount);
        assertEq(address(this).balance, holding + withdrawalAmount);
    }

    function test_rewardManagerRescueToken_success_withNonNativeAsset_withWithdrawAll()
        public
    {
        uint256 balance = dai.balanceOf(address(rewardManager));
        uint256 holding = dai.balanceOf(address(this));

        rewardManager.rescueToken(_DAI_ADDRESS, 0);

        assertEq(dai.balanceOf(address(rewardManager)), 0);
        assertEq(dai.balanceOf(address(this)), holding + balance);
    }

    function test_rewardManagerRescueToken_success_withNonNativeAsset_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 <= amount && amount <= 100e18);

        uint256 balance = dai.balanceOf(address(rewardManager));
        uint256 holding = dai.balanceOf(address(this));

        rewardManager.rescueToken(_DAI_ADDRESS, amount);

        uint256 withdrawalAmount = amount == 0 ? balance : amount;

        assertEq(
            dai.balanceOf(address(rewardManager)),
            balance - withdrawalAmount
        );
        assertEq(dai.balanceOf(address(this)), holding + withdrawalAmount);
    }
}
