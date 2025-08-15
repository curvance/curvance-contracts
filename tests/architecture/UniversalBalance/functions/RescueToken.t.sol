// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract UniversalBalanceRescueTokenTest is TestBaseUniversalBalance {
    receive() external payable {}

    function setUp() public override {
        super.setUp();

        _prepareDAI(address(universalBalance), 100e18);
        deal(address(universalBalance), 100e18);
    }

    function test_universalBalanceRescueToken_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(
            UniversalBalance.UniversalBalance__Unauthorized.selector
        );
        universalBalance.rescueToken(_DAI_ADDRESS, 100);
    }

    function test_universalBalanceRescueToken_fail_whenTokenIsUnderlyingToken()
        public
    {
        vm.expectRevert(
            UniversalBalance.UniversalBalance__InvalidParameter.selector
        );
        universalBalance.rescueToken(_USDC_ADDRESS, 100);
    }

    function test_universalBalanceRescueToken_fail_whenAmountExceedsBalance()
        public
    {
        uint256 balance = dai.balanceOf(address(universalBalance));

        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        universalBalance.rescueToken(_DAI_ADDRESS, balance + 1);
    }

    function test_universalBalanceRescueToken_success_withNativeAsset_withWithdrawAll()
        public
    {
        uint256 balance = address(universalBalance).balance;
        uint256 holding = address(this).balance;

        universalBalance.rescueToken(address(0), 0);

        assertEq(address(universalBalance).balance, 0);
        assertEq(address(this).balance, holding + balance);
    }

    function test_universalBalanceRescueToken_success_withNativeAsset_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 <= amount && amount <= 100e18);

        uint256 balance = address(universalBalance).balance;
        uint256 holding = address(this).balance;

        universalBalance.rescueToken(address(0), amount);

        uint256 withdrawalAmount = amount == 0 ? balance : amount;

        assertEq(
            address(universalBalance).balance,
            balance - withdrawalAmount
        );
        assertEq(address(this).balance, holding + withdrawalAmount);
    }

    function test_universalBalanceRescueToken_success_withNonNativeAsset_withWithdrawAll()
        public
    {
        uint256 balance = dai.balanceOf(address(universalBalance));
        uint256 holding = dai.balanceOf(address(this));

        universalBalance.rescueToken(_DAI_ADDRESS, 0);

        assertEq(dai.balanceOf(address(universalBalance)), 0);
        assertEq(dai.balanceOf(address(this)), holding + balance);
    }

    function test_universalBalanceRescueToken_success_withNonNativeAsset_fuzzed(
        uint256 amount
    ) public {
        vm.assume(0 <= amount && amount <= 100e18);

        uint256 balance = dai.balanceOf(address(universalBalance));
        uint256 holding = dai.balanceOf(address(this));

        universalBalance.rescueToken(_DAI_ADDRESS, amount);

        uint256 withdrawalAmount = amount == 0 ? balance : amount;

        assertEq(
            dai.balanceOf(address(universalBalance)),
            balance - withdrawalAmount
        );
        assertEq(dai.balanceOf(address(this)), holding + withdrawalAmount);
    }
}
