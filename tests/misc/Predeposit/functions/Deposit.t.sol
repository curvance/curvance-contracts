// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBasePredeposit } from "../TestBasePredeposit.sol";
import { Predeposit } from "contracts/misc/Predeposit.sol";

contract DepositTest is TestBasePredeposit {
    event Deposited(address user, address token, uint256 amount);

    function test_deposit_fail_whenPredepositIsEnded() public {
        vm.warp(predeposit.predepositEndTimestamp() + 1);

        vm.expectRevert(
            Predeposit.Predeposit__PredepositDepositsBlocked.selector
        );
        predeposit.deposit(_USDC_ADDRESS, 100e6);
    }

    function test_deposit_fail_whenTokenIsNotApproved() public {
        vm.expectRevert(
            Predeposit.Predeposit__InvalidParameters.selector
        );

        predeposit.deposit(_WETH_ADDRESS, 100e6);
    }

    function test_deposit_success() public {
        _prepareUSDC(user1, 100e6);

        vm.startPrank(user1);

        usdc.approve(address(predeposit), 100e6);

        vm.expectEmit(true, true, true, true);
        emit Deposited(user1, _USDC_ADDRESS, 100e6);

        predeposit.deposit(_USDC_ADDRESS, 100e6);

        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), 0);
        assertEq(usdc.balanceOf(address(predeposit)), 100e6);
        assertEq(predeposit.balanceOf(user1, _USDC_ADDRESS), 100e6);
    }
}
