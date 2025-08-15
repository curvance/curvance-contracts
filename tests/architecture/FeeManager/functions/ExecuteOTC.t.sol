// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseFeeManager } from "../TestBaseFeeManager.sol";
import { FeeManager } from "contracts/architecture/FeeManager.sol";

contract ExecuteOTCTest is TestBaseFeeManager {
    function test_executeOTC_fail_whenCallerIsNotAuthorized() public {
        vm.prank(user1);

        vm.expectRevert(FeeManager.FeeManager__Unauthorized.selector);
        feeManager.executeOTC(
            _WETH_ADDRESS,
            _ONE,
            _ONE,
            1e16,
            block.timestamp + 300
        );
    }

    function test_executeOTC_fail_whenTokenIsNotEarmarked() public {
        vm.expectRevert(FeeManager.FeeManager__TokenIsNotEarmarked.selector);
        feeManager.executeOTC(
            _WETH_ADDRESS,
            _ONE,
            _ONE,
            1e16,
            block.timestamp + 300
        );
    }

    function test_executeOTC_fail_whenFeeTokenIsNotApproved() public {
        feeManager.setEarmarked(_WETH_ADDRESS, true);

        vm.expectRevert();
        feeManager.executeOTC(
            _WETH_ADDRESS,
            _ONE,
            _ONE,
            1e16,
            block.timestamp + 300
        );
    }

    function test_executeOTC_fail_whenPriceIsInvalid() public {
        feeManager.setEarmarked(_WETH_ADDRESS, true);

        mockWethFeed.setMockAnswer(-1);
        _refreshMockFeeds();

        vm.expectRevert(FeeManager.FeeManager__ConfigurationError.selector);
        feeManager.executeOTC(
            _WETH_ADDRESS,
            _ONE,
            _ONE,
            0,
            block.timestamp + 300
        );
    }

    function test_executeOTC_fail_whenSlippageWasTooHigh() public {
        feeManager.setEarmarked(_WETH_ADDRESS, true);

        _prepareUSDC(address(this), _ONE);
        _prepareWETH(address(feeManager), _ONE);
        usdc.approve(address(feeManager), _ONE);

        vm.expectRevert(
            FeeManager.FeeManager__OTCExecutionTermsFailed.selector
        );
        feeManager.executeOTC(
            _WETH_ADDRESS,
            _ONE,
            100e6,
            1e16,
            block.timestamp + 300
        );
    }

    function test_executeOTC_whenDeadlineExpired() public {
        feeManager.setEarmarked(_WETH_ADDRESS, true);

        _prepareUSDC(address(this), _ONE);
        _prepareWETH(address(feeManager), _ONE);
        usdc.approve(address(feeManager), _ONE);

        vm.expectRevert(
            FeeManager.FeeManager__OTCExecutionTermsFailed.selector
        );
        feeManager.executeOTC(
            _WETH_ADDRESS,
            _ONE,
            _ONE,
            1e16,
            block.timestamp - 300
        );
    }

    function test_executeOTC_success() public {
        feeManager.setEarmarked(_WETH_ADDRESS, true);

        _prepareUSDC(address(this), _ONE);
        _prepareWETH(address(feeManager), _ONE);
        uint256 feeBalanceBefore = usdc.balanceOf(address(this));

        assertEq(weth.balanceOf(address(this)), 0);
        assertEq(usdc.balanceOf(address(centralRegistry)), 0);

        usdc.approve(address(feeManager), _ONE);

        mockWethFeed.setMockAnswer(1500e8);
        mockUsdcFeed.setMockAnswer(1e8);

        _refreshMockFeeds();

        // Eth spoofed as $1500, USDC spoofed as $1
        feeManager.executeOTC(
            _WETH_ADDRESS,
            _ONE,
            1500e6,
            1e16,
            block.timestamp + 300
        );

        assertEq(usdc.balanceOf(address(feeManager)), 1500e6);
        assertEq(usdc.balanceOf(address(this)), feeBalanceBefore - 1500e6);

        assertEq(weth.balanceOf(address(feeManager)), 0);
        assertEq(weth.balanceOf(address(this)), _ONE);
    }
}
