// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseCurvancePrefarm } from "../TestBaseCurvancePrefarm.sol";
import { CurvancePrefarm } from "contracts/misc/CurvancePrefarm.sol";

contract DepositTest is TestBaseCurvancePrefarm {
    event Deposited(address user, address token, uint256 amount);

    function test_deposit_fail_whenPrefarmIsEnded() public {
        vm.warp(curvancePrefarm.prefarmEndTimestamp() + 1);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__PrefarmDepositsBlocked.selector
        );
        curvancePrefarm.deposit(_USDC_ADDRESS, 100e6);
    }

    function test_deposit_fail_whenUnapprovedToken() public {
        deal(_WETH_ADDRESS, user1, 100e6);

        vm.startPrank(user1);

        weth.approve(address(curvancePrefarm), 100e6);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__InvalidParameters.selector
        );

        curvancePrefarm.deposit(_WETH_ADDRESS, 100e6);
    }


    function test_deposit_success() public {
        deal(_USDC_ADDRESS, user1, 100e6);

        vm.startPrank(user1);

        usdc.approve(address(curvancePrefarm), 100e6);

        vm.expectEmit(true, true, true, true);
        emit Deposited(user1, _USDC_ADDRESS, 100e6);

        curvancePrefarm.deposit(_USDC_ADDRESS, 100e6);

        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), 0);
        assertEq(usdc.balanceOf(address(curvancePrefarm)), 100e6);
        assertEq(curvancePrefarm.balanceOf(user1, _USDC_ADDRESS), 100e6);
    }
}
