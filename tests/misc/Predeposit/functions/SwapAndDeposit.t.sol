// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBasePredeposit } from "../TestBasePredeposit.sol";
import { Predeposit } from "contracts/misc/Predeposit.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

contract SwapAndDepositTest is TestBasePredeposit {
    event Deposited(address user, address token, uint256 amount);

    SwapperLib.Swap public swapAction;

    function setUp() public override {
        super.setUp();

        swapAction.inputToken = _WETH_ADDRESS;
        swapAction.inputAmount = _ONE;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V2_ROUTER;
        swapAction.slippage = 50e16;

        address[] memory path = new address[](2);
        path[0] = _WETH_ADDRESS;
        path[1] = _USDC_ADDRESS;

        swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            _ONE,
            0,
            path,
            address(predeposit),
            block.timestamp
        );

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );
    }

    function test_swapAndDeposit_fail_whenPredepositIsEnded() public {
        vm.warp(predeposit.predepositEndTimestamp() + 1);

        vm.expectRevert(
            Predeposit.Predeposit__PredepositDepositsBlocked.selector
        );
        predeposit.swapAndDeposit(swapAction, 100e6);
    }

    function test_swapAndDeposit_fail_whenTokenIsNotApproved() public {
        swapAction.outputToken = _WETH_ADDRESS;

        vm.expectRevert(
            Predeposit.Predeposit__InvalidParameters.selector
        );

        predeposit.swapAndDeposit(swapAction, 100e6);
    }

    function test_swapAndDeposit_fail_whenMsgValueIsInvalid() public {
        swapAction.inputToken = address(0);

        vm.expectRevert(
            Predeposit.Predeposit__InvalidSwapAction.selector
        );

        predeposit.swapAndDeposit(swapAction, 100e6);
    }

    function test_swapAndDeposit_fail_whenSwappedAmountIsNotEnoughToDeposit()
        public
    {
        _prepareWETH(user1, _ONE);

        vm.startPrank(user1);

        weth.approve(address(predeposit), _ONE);

        vm.expectRevert(
            Predeposit.Predeposit__InvalidSwapOutput.selector
        );

        predeposit.swapAndDeposit(swapAction, 100_000e6);

        vm.stopPrank();
    }

    function test_swapAndDeposit_success() public {
        _prepareWETH(user1, _ONE);

        assertEq(weth.balanceOf(user1), _ONE);
        assertEq(usdc.balanceOf(user1), 0);

        vm.startPrank(user1);

        weth.approve(address(predeposit), _ONE);

        vm.expectEmit(true, true, true, true);
        emit Deposited(user1, _USDC_ADDRESS, 100e6);

        predeposit.swapAndDeposit(swapAction, 100e6);

        vm.stopPrank();

        assertEq(weth.balanceOf(user1), 0);
        assertGt(usdc.balanceOf(user1), 0);
        assertEq(usdc.balanceOf(address(predeposit)), 100e6);
        assertEq(predeposit.balanceOf(user1, _USDC_ADDRESS), 100e6);
    }
}
