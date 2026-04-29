// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseZapper } from "contracts/plugins/BaseZapper.sol";
import { VelodromeZapper } from "contracts/plugins/market/VelodromeZapper.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { TestVelodromeZapper } from "tests/plugins/market/velodromeZapper/integrations/TestVelodromeZapper.t.sol";

contract TC006VelodromeZeroSwapExitAccountingPoC is TestVelodromeZapper {
    struct ExitObservation {
        uint256 outAmount;
        uint256 receiverWethDelta;
        uint256 receiverUsdcDelta;
        uint256 zapperUsdcDelta;
        uint256 zapperWethAfter;
        uint256 receiverLpAfter;
    }

    function test_tc006_exitVelodrome_zeroSwapRefundsSiblingLegToReceiver()
        public
    {
        deal(_VELODROME_WETH_USDC, user1, 0.05 ether);

        ExitObservation memory observation = _runDirectZeroSwapExit(
            IERC20(_VELODROME_WETH_USDC).balanceOf(user1)
        );

        _assertZeroSwapRefundAccounting(observation, "tc006:direct-exit");
    }

    function test_tc006_redeemAndExitVelodrome_zeroSwapRefundsSiblingLegToReceiver()
        public
    {
        _seedVelodromeCTokenPosition();

        ExitObservation memory observation = _runRedeemZeroSwapExit();

        _assertZeroSwapRefundAccounting(observation, "tc006:redeem-exit");
    }

    function _runDirectZeroSwapExit(
        uint256 withdrawAmount
    ) internal returns (ExitObservation memory observation) {
        uint256 receiverWethBefore = IERC20(_WETH).balanceOf(user1);
        uint256 receiverUsdcBefore = IERC20(_USDC).balanceOf(user1);
        uint256 zapperUsdcBefore = IERC20(_USDC).balanceOf(address(velodromeZapper));

        vm.startPrank(user1);
        IERC20(_VELODROME_WETH_USDC).approve(
            address(velodromeZapper),
            withdrawAmount
        );
        observation.outAmount = velodromeZapper.exitVelodrome(
            _VELODROME_ROUTER,
            VelodromeZapper.ZapAction(
                _VELODROME_WETH_USDC,
                withdrawAmount,
                _WETH,
                0,
                false
            ),
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();

        observation.receiverWethDelta =
            IERC20(_WETH).balanceOf(user1) -
            receiverWethBefore;
        observation.receiverUsdcDelta =
            IERC20(_USDC).balanceOf(user1) -
            receiverUsdcBefore;
        observation.zapperUsdcDelta =
            IERC20(_USDC).balanceOf(address(velodromeZapper)) -
            zapperUsdcBefore;
        observation.zapperWethAfter = IERC20(_WETH).balanceOf(address(velodromeZapper));
        observation.receiverLpAfter = IERC20(_VELODROME_WETH_USDC).balanceOf(user1);
    }

    function _runRedeemZeroSwapExit()
        internal
        returns (ExitObservation memory observation)
    {
        uint256 receiverWethBefore = IERC20(_WETH).balanceOf(user1);
        uint256 receiverUsdcBefore = IERC20(_USDC).balanceOf(user1);
        uint256 zapperUsdcBefore = IERC20(_USDC).balanceOf(address(velodromeZapper));

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(veloCTokenWETHUSDC);
        redeemAction.shares = 0.00006 ether;
        redeemAction.forceRedeemCollateral = false;

        vm.startPrank(user1);
        veloCTokenWETHUSDC.setDelegateApproval(address(velodromeZapper), true);
        observation.outAmount = velodromeZapper.redeemAndExitVelodrome(
            redeemAction,
            _VELODROME_ROUTER,
            VelodromeZapper.ZapAction(
                _VELODROME_WETH_USDC,
                0.00006 ether,
                _WETH,
                0,
                false
            ),
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();

        observation.receiverWethDelta =
            IERC20(_WETH).balanceOf(user1) -
            receiverWethBefore;
        observation.receiverUsdcDelta =
            IERC20(_USDC).balanceOf(user1) -
            receiverUsdcBefore;
        observation.zapperUsdcDelta =
            IERC20(_USDC).balanceOf(address(velodromeZapper)) -
            zapperUsdcBefore;
        observation.zapperWethAfter = IERC20(_WETH).balanceOf(address(velodromeZapper));
        observation.receiverLpAfter = IERC20(_VELODROME_WETH_USDC).balanceOf(user1);
    }

    function _seedVelodromeCTokenPosition() internal {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        vm.startPrank(user1);
        velodromeZapper.enterVelodrome{ value: ethAmount }(
            address(veloCTokenWETHUSDC),
            VelodromeZapper.ZapAction(
                address(0),
                ethAmount,
                _VELODROME_WETH_USDC,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _VELODROME_ROUTER,
            _VELODROME_FACTORY,
            6e13,
            false,
            user1
        );
        vm.stopPrank();

        assertApproxEqRel(
            veloCTokenWETHUSDC.balanceOf(user1),
            0.00006 ether,
            0.01 ether
        );
        assertEq(user1.balance, 0, "tc006:expected-entered-position");
    }

    function _assertZeroSwapRefundAccounting(
        ExitObservation memory observation,
        string memory branchLabel
    ) internal {
        assertGt(
            observation.outAmount,
            0,
            string.concat(branchLabel, ":missing-output-token")
        );
        assertEq(
            observation.receiverWethDelta,
            observation.outAmount,
            string.concat(branchLabel, ":reported-output-mismatch")
        );
        // Sibling LP leg should be refunded back to the receiver instead of
        // stranded on the zapper.
        assertGt(
            observation.receiverUsdcDelta,
            0,
            string.concat(branchLabel, ":receiver-should-be-refunded-sibling-leg")
        );
        assertEq(
            observation.zapperUsdcDelta,
            0,
            string.concat(branchLabel, ":zapper-should-not-strand-sibling-leg")
        );
        assertEq(
            observation.zapperWethAfter,
            0,
            string.concat(branchLabel, ":output-token-should-not-remain-on-zapper")
        );
        assertEq(
            observation.receiverLpAfter,
            0,
            string.concat(branchLabel, ":lp-position-should-be-fully-exited")
        );
    }
}
