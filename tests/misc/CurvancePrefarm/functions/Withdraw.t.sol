// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseCurvancePrefarm } from "../TestBaseCurvancePrefarm.sol";
import { CurvancePrefarm } from "contracts/misc/CurvancePrefarm.sol";

contract WithdrawTest is TestBaseCurvancePrefarm {
    event WithdrawnWithPenalty(address user);

    function setUp() public override {
        super.setUp();

        _prepareUSDC(user1, 100e6);

        vm.startPrank(user1);

        usdc.approve(address(curvancePrefarm), 100e6);
        curvancePrefarm.deposit(_USDC_ADDRESS, 100e6);

        vm.stopPrank();
    }

    function test_withdraw_fail_whenExceedsDepositedAmount() public {
        vm.prank(user1);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__InvalidParameters.selector
        );
        curvancePrefarm.withdraw(_USDC_ADDRESS, 100e6 + 1);
    }

    function test_withdraw_success() public {
        assertEq(usdc.balanceOf(user1), 0);
        assertEq(usdc.balanceOf(address(curvancePrefarm)), 100e6);
        assertEq(curvancePrefarm.balanceOf(user1, _USDC_ADDRESS), 100e6);

        vm.startPrank(user1);

        vm.expectEmit(true, true, true, true);
        emit WithdrawnWithPenalty(user1);

        curvancePrefarm.withdraw(_USDC_ADDRESS, 100e6);

        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), 100e6);
        assertEq(usdc.balanceOf(address(curvancePrefarm)), 0);
        assertEq(curvancePrefarm.balanceOf(user1, _USDC_ADDRESS), 0);
    }
}
