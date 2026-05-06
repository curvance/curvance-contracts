// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import { PendleZapperCalldataChecker } from "contracts/calldata-checker/swap-checker/PendleZapperCalldataChecker.sol";
import { PendleZapperMinimal } from "contracts/plugins/market/PendleZapperMinimal.sol";
import { PendleZapper } from "contracts/plugins/market/PendleZapper.sol";
import { BaseZapper } from "contracts/plugins/BaseZapper.sol";

import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SwapType } from "contracts/interfaces/external/pendle/IPSwapAggregator.sol";

contract TestPendleZapperCalldataChecker is Test {
    address internal pendleZapper = address(0x1000);
    address internal pendleRouter = address(0x2000);
    address internal receiver = address(0x3000);
    address internal cToken = address(0x4000);
    address internal pendleToken = address(0x5000);
    address internal outputToken = address(0x6000);

    PendleZapperCalldataChecker internal checker;
    SwapperLib.Swap internal swapAction;

    function setUp() public {
        checker = new PendleZapperCalldataChecker(pendleZapper, pendleRouter);
    }

    function test_redeemAndExit_usesRedeemSharesAsInputAmount() public {
        PendleLib.PendleAction memory action;
        BaseZapper.RedeemAction memory redeemAction = BaseZapper.RedeemAction({
            cToken: cToken,
            shares: 100,
            forceRedeemCollateral: false
        });
        PendleZapperMinimal.ZapAction memory zapAction = PendleZapperMinimal
            .ZapAction({
                inputToken: pendleToken,
                inputAmount: 50,
                outputToken: outputToken,
                minimumOut: 1,
                depositAsWrappedNative: false
            });

        swapAction = SwapperLib.Swap({
            inputToken: cToken,
            inputAmount: redeemAction.shares,
            outputToken: outputToken,
            target: pendleZapper,
            slippage: 0,
            call: _redeemAndExitCalldata(action, redeemAction, zapAction)
        });

        assertEq(
            checker.checkCalldata(swapAction, receiver),
            zapAction.minimumOut
        );
    }

    function test_redeemAndExit_revertsWhenInputAmountMatchesZapAmountInsteadOfShares()
        public
    {
        PendleLib.PendleAction memory action;
        BaseZapper.RedeemAction memory redeemAction = BaseZapper.RedeemAction({
            cToken: cToken,
            shares: 100,
            forceRedeemCollateral: false
        });
        PendleZapperMinimal.ZapAction memory zapAction = PendleZapperMinimal
            .ZapAction({
                inputToken: pendleToken,
                inputAmount: 50,
                outputToken: outputToken,
                minimumOut: 1,
                depositAsWrappedNative: false
            });

        swapAction = SwapperLib.Swap({
            inputToken: cToken,
            inputAmount: zapAction.inputAmount,
            outputToken: outputToken,
            target: pendleZapper,
            slippage: 0,
            call: _redeemAndExitCalldata(action, redeemAction, zapAction)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InputAmountError.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_revertsWrongPendleRouter() public {
        PendleLib.PendleAction memory action;
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: zapAction.outputToken,
            target: pendleZapper,
            slippage: 0,
            call: abi.encodeWithSelector(
                PendleZapper.exitPendle.selector,
                pendleToken,
                address(0xBAD),
                false,
                action,
                zapAction,
                new SwapperLib.Swap[](0),
                receiver
            )
        });

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, receiver);
    }

    function test_revertsWrongRecipient() public {
        PendleLib.PendleAction memory action;
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: zapAction.outputToken,
            target: pendleZapper,
            slippage: 0,
            call: _exitCalldata(action, zapAction)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__RecipientError.selector
        );
        checker.checkCalldata(swapAction, address(0xBAD));
    }

    function test_revertsZeroMinimumOut() public {
        PendleLib.PendleAction memory action;
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();
        zapAction.minimumOut = 0;

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: zapAction.outputToken,
            target: pendleZapper,
            slippage: 0,
            call: _exitCalldata(action, zapAction)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidMinOut.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_enterPendle_usesCTokenAsOutputWhenProvided() public {
        PendleLib.PendleAction memory action;
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();
        uint256 expectedShares = 42;

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: pendleZapper,
            slippage: 0,
            call: _enterCalldata(cToken, action, zapAction, expectedShares)
        });

        assertEq(checker.checkCalldata(swapAction, receiver), expectedShares);
    }

    function test_enterPendle_revertsWhenCTokenIsZero() public {
        PendleLib.PendleAction memory action;
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: zapAction.outputToken,
            target: pendleZapper,
            slippage: 0,
            call: _enterCalldata(address(0), action, zapAction, 42)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__OutputTokenError.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_enterPendle_revertsWhenExpectedSharesIsZero() public {
        PendleLib.PendleAction memory action;
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: pendleZapper,
            slippage: 0,
            call: _enterCalldata(cToken, action, zapAction, 0)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidMinOut.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_enterPendle_revertsWhenPendleMinimumOutIsZero() public {
        PendleLib.PendleAction memory action;
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();
        zapAction.minimumOut = 0;

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: pendleZapper,
            slippage: 0,
            call: _enterCalldata(cToken, action, zapAction, 42)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidMinOut.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_doesNotInspectPendleSdkAggregatorRoute() public {
        PendleLib.PendleAction memory action;
        action.output.pendleSwap = address(0xBEEF);
        action.output.swapData.swapType = SwapType.KYBERSWAP;
        action.output.swapData.extRouter = address(0xCAFE);
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: zapAction.outputToken,
            target: pendleZapper,
            slippage: 0,
            call: abi.encodeWithSelector(
                PendleZapper.exitPendle.selector,
                pendleToken,
                pendleRouter,
                false,
                action,
                zapAction,
                new SwapperLib.Swap[](0),
                receiver
            )
        });

        assertEq(
            checker.checkCalldata(swapAction, receiver),
            zapAction.minimumOut
        );
    }

    function test_doesNotInspectPendleLimitRouter() public {
        PendleLib.PendleAction memory action;
        action.limit.limitRouter = address(0xBEEF);
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: zapAction.outputToken,
            target: pendleZapper,
            slippage: 0,
            call: abi.encodeWithSelector(
                PendleZapper.exitPendle.selector,
                pendleToken,
                pendleRouter,
                false,
                action,
                zapAction,
                new SwapperLib.Swap[](0),
                receiver
            )
        });

        assertEq(
            checker.checkCalldata(swapAction, receiver),
            zapAction.minimumOut
        );
    }

    function _defaultZapAction()
        internal
        view
        returns (PendleZapperMinimal.ZapAction memory)
    {
        return
            PendleZapperMinimal.ZapAction({
                inputToken: pendleToken,
                inputAmount: 100,
                outputToken: outputToken,
                minimumOut: 1,
                depositAsWrappedNative: false
            });
    }

    function _enterCalldata(
        address cToken_,
        PendleLib.PendleAction memory action,
        PendleZapperMinimal.ZapAction memory zapAction,
        uint256 expectedShares
    ) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                PendleZapperMinimal.enterPendle.selector,
                cToken_,
                pendleRouter,
                false,
                action,
                zapAction,
                new SwapperLib.Swap[](0),
                expectedShares,
                false,
                receiver
            );
    }

    function _exitCalldata(
        PendleLib.PendleAction memory action,
        PendleZapperMinimal.ZapAction memory zapAction
    ) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                PendleZapper.exitPendle.selector,
                pendleToken,
                pendleRouter,
                false,
                action,
                zapAction,
                new SwapperLib.Swap[](0),
                receiver
            );
    }

    function _redeemAndExitCalldata(
        PendleLib.PendleAction memory action,
        BaseZapper.RedeemAction memory redeemAction,
        PendleZapperMinimal.ZapAction memory zapAction
    ) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                PendleZapper.redeemAndExitPendle.selector,
                pendleToken,
                pendleRouter,
                false,
                action,
                redeemAction,
                zapAction,
                new SwapperLib.Swap[](0),
                receiver
            );
    }
}
