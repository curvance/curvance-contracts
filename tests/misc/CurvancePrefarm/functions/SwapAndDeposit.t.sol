// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseCurvancePrefarm } from "../TestBaseCurvancePrefarm.sol";
import { CurvancePrefarm } from "contracts/misc/CurvancePrefarm.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

contract SwapAndDepositTest is TestBaseCurvancePrefarm {
    event Deposited(address user, address token, uint256 amount);

    SwapperLib.Swap public swapData;

    function setUp() public override {
        super.setUp();

        swapData.inputToken = _WETH_ADDRESS;
        swapData.inputAmount = _ONE;
        swapData.outputToken = _USDC_ADDRESS;
        swapData.target = _UNISWAP_V2_ROUTER;
        swapData.slippage = 50e16;

        address[] memory path = new address[](2);
        path[0] = _WETH_ADDRESS;
        path[1] = _USDC_ADDRESS;

        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            _ONE,
            0,
            path,
            address(curvancePrefarm),
            block.timestamp
        );

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );
    }

    function test_swapAndDeposit_fail_whenPrefarmIsEnded() public {
        vm.warp(curvancePrefarm.prefarmEndTimestamp() + 1);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__PrefarmDepositsBlocked.selector
        );
        curvancePrefarm.swapAndDeposit(swapData, 100e6);
    }

    function test_swapAndDeposit_fail_whenTokenIsNotApproved() public {
        swapData.outputToken = _WETH_ADDRESS;

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__InvalidParameters.selector
        );

        curvancePrefarm.swapAndDeposit(swapData, 100e6);
    }

    function test_swapAndDeposit_fail_whenMsgValueIsInvalid() public {
        swapData.inputToken = address(0);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__InvalidSwapData.selector
        );

        curvancePrefarm.swapAndDeposit(swapData, 100e6);
    }

    function test_swapAndDeposit_fail_whenSwappedAmountIsNotEnoughToDeposit()
        public
    {
        deal(_WETH_ADDRESS, user1, _ONE);

        vm.startPrank(user1);

        weth.approve(address(curvancePrefarm), _ONE);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__InvalidSwapOutput.selector
        );

        curvancePrefarm.swapAndDeposit(swapData, 100_000e6);

        vm.stopPrank();
    }

    function test_swapAndDeposit_success() public {
        deal(_WETH_ADDRESS, user1, _ONE);

        assertEq(weth.balanceOf(user1), _ONE);
        assertEq(usdc.balanceOf(user1), 0);

        vm.startPrank(user1);

        weth.approve(address(curvancePrefarm), _ONE);

        vm.expectEmit(true, true, true, true);
        emit Deposited(user1, _USDC_ADDRESS, 100e6);

        curvancePrefarm.swapAndDeposit(swapData, 100e6);

        vm.stopPrank();

        assertEq(weth.balanceOf(user1), 0);
        assertGt(usdc.balanceOf(user1), 0);
        assertEq(usdc.balanceOf(address(curvancePrefarm)), 100e6);
        assertEq(curvancePrefarm.balanceOf(user1, _USDC_ADDRESS), 100e6);
    }
}
