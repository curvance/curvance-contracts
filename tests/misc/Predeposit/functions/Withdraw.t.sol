// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBasePredeposit } from "../TestBasePredeposit.sol";
import { Predeposit } from "contracts/misc/Predeposit.sol";

contract WithdrawTest is TestBasePredeposit {
    event WithdrawnWithPenalty(address user);

    function setUp() public override {
        super.setUp();

        _prepareUSDC(user1, 100e6);

        vm.startPrank(user1);

        usdc.approve(address(predeposit), 100e6);
        predeposit.deposit(_USDC_ADDRESS, 100e6);

        vm.stopPrank();
    }

    function test_withdraw_fail_whenExceedsDepositedAmount() public {
        vm.prank(user1);

        vm.expectRevert(
            Predeposit.Predeposit__InvalidParameters.selector
        );
        predeposit.withdraw(_USDC_ADDRESS, 100e6 + 1);
    }

    function test_withdraw_success() public {
        assertEq(usdc.balanceOf(user1), 0);
        assertEq(usdc.balanceOf(address(predeposit)), 100e6);
        assertEq(predeposit.balanceOf(user1, _USDC_ADDRESS), 100e6);

        vm.startPrank(user1);

        vm.expectEmit(true, true, true, true);
        emit WithdrawnWithPenalty(user1);

        predeposit.withdraw(_USDC_ADDRESS, 100e6);

        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), 100e6);
        assertEq(usdc.balanceOf(address(predeposit)), 0);
        assertEq(predeposit.balanceOf(user1, _USDC_ADDRESS), 0);
    }
}
