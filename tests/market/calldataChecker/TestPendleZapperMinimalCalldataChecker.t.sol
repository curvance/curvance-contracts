// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    BaseSwapChecker
} from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import {
    PendleZapperMinimalCalldataChecker
} from "contracts/calldata-checker/swap-checker/PendleZapperMinimalCalldataChecker.sol";
import {
    PendleZapperMinimal
} from "contracts/plugins/market/PendleZapperMinimal.sol";
import {PendleZapper} from "contracts/plugins/market/PendleZapper.sol";
import {BaseZapper} from "contracts/plugins/BaseZapper.sol";

import {PendleLib} from "contracts/libraries/PendleLib.sol";
import {SwapperLib} from "contracts/libraries/SwapperLib.sol";

contract TestPendleZapperMinimalCalldataChecker is Test {
    address internal pendleZapper = address(0x1000);
    address internal pendleRouter = address(0x2000);
    address internal receiver = address(0x3000);
    address internal cToken = address(0x4000);
    address internal inputToken = address(0x5000);
    address internal outputToken = address(0x6000);
    address internal pendleMarket = address(0x7000);

    PendleZapperMinimalCalldataChecker internal checker;
    SwapperLib.Swap internal swapAction;

    function setUp() public {
        checker =
            new PendleZapperMinimalCalldataChecker(pendleZapper, pendleRouter);
    }

    function test_enterPendle_usesExpectedSharesAsFinalMinOut() public {
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

    function test_enterPendle_acceptsPTTupleWithoutInspectingPendleMarket()
        public
    {
        PendleLib.PendleAction memory action;
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();
        zapAction.outputToken = outputToken;
        uint256 expectedShares = 42;

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: pendleZapper,
            slippage: 0,
            call: _enterCalldataWithRoute(
                cToken,
                action,
                zapAction,
                expectedShares,
                address(0xBEEF),
                true
            )
        });

        assertEq(
            checker.checkCalldata(swapAction, receiver),
            expectedShares,
            "checker MUST leave PT market validation to zapper execution"
        );
    }

    function test_enterPendle_revertsLpMode() public {
        PendleLib.PendleAction memory action;
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: pendleZapper,
            slippage: 0,
            call: _enterCalldataWithRoute(
                cToken,
                action,
                zapAction,
                42,
                pendleMarket,
                false
            )
        });

        vm.expectRevert(
            PendleZapperMinimalCalldataChecker
                .PendleZapperMinimalCalldataChecker__InvalidPendleMode
                .selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_revertsExitPendle() public {
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
                outputToken,
                pendleRouter,
                pendleMarket,
                false,
                action,
                zapAction,
                new SwapperLib.Swap[](0),
                receiver
            )
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidFuncSig.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_revertsRedeemAndExitPendle() public {
        PendleLib.PendleAction memory action;
        BaseZapper.RedeemAction memory redeemAction = BaseZapper.RedeemAction({
            cToken: cToken, shares: 100, forceRedeemCollateral: false
        });
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();

        swapAction = SwapperLib.Swap({
            inputToken: cToken,
            inputAmount: 100,
            outputToken: outputToken,
            target: pendleZapper,
            slippage: 0,
            call: abi.encodeWithSelector(
                PendleZapper.redeemAndExitPendle.selector,
                outputToken,
                pendleRouter,
                pendleMarket,
                false,
                action,
                redeemAction,
                zapAction,
                new SwapperLib.Swap[](0),
                receiver
            )
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidFuncSig.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_revertsWrongPendleRouter() public {
        PendleLib.PendleAction memory action;
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: pendleZapper,
            slippage: 0,
            call: abi.encodeWithSelector(
                PendleZapperMinimal.enterPendle.selector,
                cToken,
                address(0xBAD),
                pendleMarket,
                false,
                action,
                zapAction,
                new SwapperLib.Swap[](0),
                42,
                false,
                receiver
            )
        });

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, receiver);
    }

    function test_revertsWrongSwapTarget() public {
        PendleLib.PendleAction memory action;
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: address(0xBAD),
            slippage: 0,
            call: _enterCalldata(cToken, action, zapAction, 42)
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
            outputToken: cToken,
            target: pendleZapper,
            slippage: 0,
            call: _enterCalldata(cToken, action, zapAction, 42)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__RecipientError.selector
        );
        checker.checkCalldata(swapAction, address(0xBAD));
    }

    function test_revertsWhenCTokenIsZero() public {
        PendleLib.PendleAction memory action;
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: pendleZapper,
            slippage: 0,
            call: _enterCalldata(address(0), action, zapAction, 42)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__OutputTokenError.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_revertsWhenFinalOutputIsNotCToken() public {
        PendleLib.PendleAction memory action;
        PendleZapperMinimal.ZapAction memory zapAction = _defaultZapAction();

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: zapAction.outputToken,
            target: pendleZapper,
            slippage: 0,
            call: _enterCalldata(cToken, action, zapAction, 42)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__OutputTokenError.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_revertsZeroExpectedShares() public {
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

    function test_revertsZeroPendleMinimumOut() public {
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

    function _defaultZapAction()
        internal
        view
        returns (PendleZapperMinimal.ZapAction memory)
    {
        return PendleZapperMinimal.ZapAction({
            inputToken: inputToken,
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
        return _enterCalldataWithRoute(
            cToken_, action, zapAction, expectedShares, pendleMarket, true
        );
    }

    function _enterCalldataWithRoute(
        address cToken_,
        PendleLib.PendleAction memory action,
        PendleZapperMinimal.ZapAction memory zapAction,
        uint256 expectedShares,
        address pendleMarket_,
        bool isPt
    ) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            PendleZapperMinimal.enterPendle.selector,
            cToken_,
            pendleRouter,
            pendleMarket_,
            isPt,
            action,
            zapAction,
            new SwapperLib.Swap[](0),
            expectedShares,
            false,
            receiver
        );
    }
}
