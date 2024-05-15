// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseFeeAccumulator } from "../TestBaseFeeAccumulator.sol";
import { FeeAccumulator } from "contracts/architecture/FeeAccumulator.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract ExecuteOTCTest is TestBaseFeeAccumulator {
    function test_executeOTC_fail_whenCallerIsNotAuthorized() public {
        vm.prank(user1);

        vm.expectRevert(FeeAccumulator.FeeAccumulator__Unauthorized.selector);
        feeAccumulator.executeOTC(_WETH_ADDRESS, _ONE);
    }

    function test_executeOTC_fail_whenTokenIsNotEarmarked() public {
        vm.expectRevert(
            FeeAccumulator.FeeAccumulator__TokenIsNotEarmarked.selector
        );
        feeAccumulator.executeOTC(_WETH_ADDRESS, _ONE);
    }

    function test_executeOTC_fail_whenFeeTokenIsNotApproved() public {
        feeAccumulator.setEarmarked(_WETH_ADDRESS, true);

        vm.expectRevert();
        feeAccumulator.executeOTC(_WETH_ADDRESS, _ONE);
    }

    function test_executeOTC_success() public {
        feeAccumulator.setEarmarked(_WETH_ADDRESS, true);

        deal(_USDC_ADDRESS, address(this), _ONE);
        deal(_WETH_ADDRESS, address(feeAccumulator), _ONE);

        assertEq(IERC20(_WETH_ADDRESS).balanceOf(address(this)), 0);
        assertEq(usdc.balanceOf(address(centralRegistry)), 0);

        usdc.approve(address(feeAccumulator), _ONE);

        feeAccumulator.executeOTC(_WETH_ADDRESS, _ONE);

        assertLt(usdc.balanceOf(address(this)), _ONE);
        assertLt(
            IERC20(_WETH_ADDRESS).balanceOf(address(feeAccumulator)),
            _ONE
        );
        assertEq(IERC20(_WETH_ADDRESS).balanceOf(address(this)), _ONE);
    }
}
