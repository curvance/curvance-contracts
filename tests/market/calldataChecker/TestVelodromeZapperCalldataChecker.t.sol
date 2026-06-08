// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    BaseSwapChecker
} from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import {
    VelodromeZapperCalldataChecker
} from "contracts/calldata-checker/swap-checker/VelodromeZapperCalldataChecker.sol";
import {VelodromeZapper} from "contracts/plugins/market/VelodromeZapper.sol";
import {BaseZapper} from "contracts/plugins/BaseZapper.sol";

import {SwapperLib} from "contracts/libraries/SwapperLib.sol";

contract TestVelodromeZapperCalldataChecker is Test {
    address internal velodromeZapper = address(0x1000);
    address internal receiver = address(0x2000);
    address internal cToken = address(0x3000);
    address internal veloPair = address(0x4000);
    address internal outputToken = address(0x5000);
    address internal router = address(0x6000);
    address internal factory = address(0x7000);

    VelodromeZapperCalldataChecker internal checker;
    SwapperLib.Swap internal swapAction;

    function setUp() public {
        checker = new VelodromeZapperCalldataChecker(
            velodromeZapper,
            router,
            factory
        );
    }

    function test_enterVelodrome_usesExpectedSharesWhenCTokenProvided()
        public
    {
        VelodromeZapper.ZapAction memory zapAction =
            VelodromeZapper.ZapAction({
                inputToken: outputToken,
                inputAmount: 50,
                outputToken: veloPair,
                minimumOut: 1,
                depositAsWrappedNative: false
            });
        uint256 expectedShares = 100;

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: velodromeZapper,
            slippage: 0,
            call: _enterCalldata(cToken, zapAction, expectedShares)
        });

        assertEq(
            checker.checkCalldata(swapAction, receiver),
            expectedShares,
            "enter checker should return cToken share floor"
        );
    }

    function test_enterVelodrome_revertsWhenExpectedSharesIsZero() public {
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: outputToken,
            inputAmount: 50,
            outputToken: veloPair,
            minimumOut: 1,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: velodromeZapper,
            slippage: 0,
            call: _enterCalldata(cToken, zapAction, 0)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidMinOut.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_enterVelodrome_revertsWhenZapMinimumOutIsZero() public {
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: outputToken,
            inputAmount: 50,
            outputToken: veloPair,
            minimumOut: 0,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: velodromeZapper,
            slippage: 0,
            call: _enterCalldata(cToken, zapAction, 100)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidMinOut.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_enterVelodrome_revertsWhenCTokenIsZero() public {
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: outputToken,
            inputAmount: 50,
            outputToken: veloPair,
            minimumOut: 1,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: veloPair,
            target: velodromeZapper,
            slippage: 0,
            call: _enterCalldata(address(0), zapAction, 100)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__OutputTokenError.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_enterVelodrome_revertsWhenFinalOutputMatchesLpInsteadOfCToken()
        public
    {
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: outputToken,
            inputAmount: 50,
            outputToken: veloPair,
            minimumOut: 1,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: veloPair,
            target: velodromeZapper,
            slippage: 0,
            call: _enterCalldata(cToken, zapAction, 100)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__OutputTokenError.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_exitVelodrome_usesZapInputAmountAndMinimumOut() public {
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: veloPair,
            inputAmount: 50,
            outputToken: outputToken,
            minimumOut: 7,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: veloPair,
            inputAmount: zapAction.inputAmount,
            outputToken: outputToken,
            target: velodromeZapper,
            slippage: 0,
            call: _exitCalldata(zapAction)
        });

        assertEq(
            checker.checkCalldata(swapAction, receiver),
            zapAction.minimumOut,
            "exit checker should return zap minimum out"
        );
    }

    function test_exitVelodrome_revertsWhenOutputTokenIsWrong() public {
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: veloPair,
            inputAmount: 50,
            outputToken: outputToken,
            minimumOut: 7,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: veloPair,
            inputAmount: zapAction.inputAmount,
            outputToken: address(0x9994),
            target: velodromeZapper,
            slippage: 0,
            call: _exitCalldata(zapAction)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__OutputTokenError.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_exitVelodrome_revertsWhenMinimumOutIsZero() public {
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: veloPair,
            inputAmount: 50,
            outputToken: outputToken,
            minimumOut: 0,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: veloPair,
            inputAmount: zapAction.inputAmount,
            outputToken: outputToken,
            target: velodromeZapper,
            slippage: 0,
            call: _exitCalldata(zapAction)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidMinOut.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_redeemAndExit_usesRedeemSharesAsInputAmount() public {
        BaseZapper.RedeemAction memory redeemAction = BaseZapper.RedeemAction({
            cToken: cToken, shares: 100, forceRedeemCollateral: false
        });
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: veloPair,
            inputAmount: 50,
            outputToken: outputToken,
            minimumOut: 1,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: cToken,
            inputAmount: redeemAction.shares,
            outputToken: outputToken,
            target: velodromeZapper,
            slippage: 0,
            call: _redeemAndExitCalldata(redeemAction, zapAction)
        });

        assertEq(
            checker.checkCalldata(swapAction, receiver), zapAction.minimumOut
        );
    }

    function test_redeemAndExit_revertsWhenInputAmountMatchesZapAmountInsteadOfShares()
        public
    {
        BaseZapper.RedeemAction memory redeemAction = BaseZapper.RedeemAction({
            cToken: cToken, shares: 100, forceRedeemCollateral: false
        });
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: veloPair,
            inputAmount: 50,
            outputToken: outputToken,
            minimumOut: 1,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: cToken,
            inputAmount: zapAction.inputAmount,
            outputToken: outputToken,
            target: velodromeZapper,
            slippage: 0,
            call: _redeemAndExitCalldata(redeemAction, zapAction)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InputAmountError.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_redeemAndExit_revertsWhenOutputTokenIsWrong() public {
        BaseZapper.RedeemAction memory redeemAction = BaseZapper.RedeemAction({
            cToken: cToken, shares: 100, forceRedeemCollateral: false
        });
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: veloPair,
            inputAmount: 50,
            outputToken: outputToken,
            minimumOut: 1,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: cToken,
            inputAmount: redeemAction.shares,
            outputToken: address(0x9993),
            target: velodromeZapper,
            slippage: 0,
            call: _redeemAndExitCalldata(redeemAction, zapAction)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__OutputTokenError.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_redeemAndExit_revertsWhenMinimumOutIsZero() public {
        BaseZapper.RedeemAction memory redeemAction = BaseZapper.RedeemAction({
            cToken: cToken, shares: 100, forceRedeemCollateral: false
        });
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: veloPair,
            inputAmount: 50,
            outputToken: outputToken,
            minimumOut: 0,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: cToken,
            inputAmount: redeemAction.shares,
            outputToken: outputToken,
            target: velodromeZapper,
            slippage: 0,
            call: _redeemAndExitCalldata(redeemAction, zapAction)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidMinOut.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function test_checkCalldata_revertsWhenTargetIsWrong() public {
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: outputToken,
            inputAmount: 50,
            outputToken: veloPair,
            minimumOut: 1,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: address(0x9999),
            slippage: 0,
            call: _enterCalldata(cToken, zapAction, 100)
        });

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, receiver);
    }

    function test_enterVelodrome_revertsWhenRouterIsWrong() public {
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: outputToken,
            inputAmount: 50,
            outputToken: veloPair,
            minimumOut: 1,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: velodromeZapper,
            slippage: 0,
            call: _enterCalldataWithEndpoints(
                cToken,
                zapAction,
                100,
                address(0x9998),
                factory
            )
        });

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, receiver);
    }

    function test_enterVelodrome_revertsWhenFactoryIsWrong() public {
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: outputToken,
            inputAmount: 50,
            outputToken: veloPair,
            minimumOut: 1,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: velodromeZapper,
            slippage: 0,
            call: _enterCalldataWithEndpoints(
                cToken,
                zapAction,
                100,
                router,
                address(0x9997)
            )
        });

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, receiver);
    }

    function test_exitVelodrome_revertsWhenRouterIsWrong() public {
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: veloPair,
            inputAmount: 50,
            outputToken: outputToken,
            minimumOut: 7,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: veloPair,
            inputAmount: zapAction.inputAmount,
            outputToken: outputToken,
            target: velodromeZapper,
            slippage: 0,
            call: _exitCalldataWithRouter(zapAction, address(0x9996))
        });

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, receiver);
    }

    function test_redeemAndExit_revertsWhenRouterIsWrong() public {
        BaseZapper.RedeemAction memory redeemAction = BaseZapper.RedeemAction({
            cToken: cToken, shares: 100, forceRedeemCollateral: false
        });
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: veloPair,
            inputAmount: 50,
            outputToken: outputToken,
            minimumOut: 1,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: cToken,
            inputAmount: redeemAction.shares,
            outputToken: outputToken,
            target: velodromeZapper,
            slippage: 0,
            call: _redeemAndExitCalldataWithRouter(
                redeemAction,
                zapAction,
                address(0x9995)
            )
        });

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, receiver);
    }

    function test_checkCalldata_revertsWhenRecipientIsWrong() public {
        VelodromeZapper.ZapAction memory zapAction = VelodromeZapper.ZapAction({
            inputToken: outputToken,
            inputAmount: 50,
            outputToken: veloPair,
            minimumOut: 1,
            depositAsWrappedNative: false
        });

        swapAction = SwapperLib.Swap({
            inputToken: zapAction.inputToken,
            inputAmount: zapAction.inputAmount,
            outputToken: cToken,
            target: velodromeZapper,
            slippage: 0,
            call: _enterCalldata(cToken, zapAction, 100)
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__RecipientError.selector
        );
        checker.checkCalldata(swapAction, address(0x9999));
    }

    function test_checkCalldata_revertsWhenSelectorIsUnknown() public {
        swapAction = SwapperLib.Swap({
            inputToken: outputToken,
            inputAmount: 50,
            outputToken: cToken,
            target: velodromeZapper,
            slippage: 0,
            call: abi.encodeWithSelector(bytes4(0xdeadbeef))
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidFuncSig.selector
        );
        checker.checkCalldata(swapAction, receiver);
    }

    function _enterCalldata(
        address finalCToken,
        VelodromeZapper.ZapAction memory zapAction,
        uint256 expectedShares
    ) internal view returns (bytes memory) {
        return _enterCalldataWithEndpoints(
            finalCToken,
            zapAction,
            expectedShares,
            router,
            factory
        );
    }

    function _enterCalldataWithEndpoints(
        address finalCToken,
        VelodromeZapper.ZapAction memory zapAction,
        uint256 expectedShares,
        address veloRouter,
        address veloFactory
    ) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            VelodromeZapper.enterVelodrome.selector,
            finalCToken,
            zapAction,
            new SwapperLib.Swap[](0),
            veloRouter,
            veloFactory,
            expectedShares,
            false,
            receiver
        );
    }

    function _exitCalldata(VelodromeZapper.ZapAction memory zapAction)
        internal
        view
        returns (bytes memory)
    {
        return _exitCalldataWithRouter(zapAction, router);
    }

    function _exitCalldataWithRouter(
        VelodromeZapper.ZapAction memory zapAction,
        address veloRouter
    ) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            VelodromeZapper.exitVelodrome.selector,
            veloRouter,
            zapAction,
            new SwapperLib.Swap[](0),
            receiver
        );
    }

    function _redeemAndExitCalldata(
        BaseZapper.RedeemAction memory redeemAction,
        VelodromeZapper.ZapAction memory zapAction
    ) internal view returns (bytes memory) {
        return _redeemAndExitCalldataWithRouter(
            redeemAction,
            zapAction,
            router
        );
    }

    function _redeemAndExitCalldataWithRouter(
        BaseZapper.RedeemAction memory redeemAction,
        VelodromeZapper.ZapAction memory zapAction,
        address veloRouter
    ) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            VelodromeZapper.redeemAndExitVelodrome.selector,
            redeemAction,
            veloRouter,
            zapAction,
            new SwapperLib.Swap[](0),
            receiver
        );
    }
}
