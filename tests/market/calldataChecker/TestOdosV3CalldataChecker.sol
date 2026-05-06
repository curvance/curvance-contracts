// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { OdosV3CalldataChecker } from "contracts/calldata-checker/swap-checker/OdosV3CalldataChecker.sol";
import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import { IOdosRouterV3 } from "contracts/interfaces/external/odos/IOdosRouterV3.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import "tests/market/TestBaseMarketIsolated.sol";

contract TestOdosV3CalldataChecker is TestBaseMarketIsolated {
    address public odosRouterV3 = 0x0D05a7D3448512B78fa8A9e46c4872C88C4a0D05;
    address public odosExecutor = 0x365084B05Fa7d5028346bD21D842eD0601bAB5b8;
    OdosV3CalldataChecker public checker;

    SwapperLib.Swap public swapAction;
    address public recipient;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        checker = new OdosV3CalldataChecker(
            odosRouterV3,
            odosExecutor,
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
        );

        vm.roll(23299738);
    }

    function testCheckCallDataRevert__TargetError() public {
        swapAction.target = address(0);

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwapUnpackCheckCallDataRevert__RecipientError() public {
        recipient = address(0);
        swapAction.inputToken = 0xD533a949740bb3306d119CC777fa900bA034cd52;
        swapAction.inputAmount = 10000000000000000000000;
        swapAction.outputToken = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
        swapAction.target = odosRouterV3;
        // Generate from odos api
        swapAction
            .call = hex"30f80b4c000000000000000000000000d533a949740bb3306d119cc777fa900ba034cd5200000000000000000000000000000000000000000000021e19e0c9bab2400000000000000000000000000000365084b05fa7d5028346bd21d842ed0601bab5b80000000000000000000000006b3595068778dd592e39a122f4f5a5cf09c90fe200000000000000000000000000000000000000000000021b5ae39aa321200000000000000000000000000000000000000000000000000219bcaa16d86660000000000000000000000000000047e2d28169738039755586743e2dfcf3bd643f860000000000000000000000000000000000000000000000000000000000000180000000000000000000000000365084b05fa7d5028346bd21d842ed0601bab5b80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000070010205005501010203020102030001010403001eff00000000000000000000004ebdf703948ddcea3b11f675b4d1fba9d2414a14d533a949740bb3306d119cc777fa900ba034cd52c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2795065dcc9f64b5614c407a6efdc400da6221fb000000000000000000000000000000000";

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__RecipientError.selector
        );
        checker.checkCalldata(swapAction, address(1));
    }

    function testSwapUnpackCheckCallDataRevert__InputTokenError() public {
        recipient = address(0x47E2D28169738039755586743E2dfCF3bd643f86);
        swapAction.inputToken = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        swapAction.inputAmount = 10000000000000000000000;
        swapAction.outputToken = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
        swapAction.target = odosRouterV3;
        // Generate from Odos api.
        swapAction
            .call = hex"30f80b4c000000000000000000000000d533a949740bb3306d119cc777fa900ba034cd5200000000000000000000000000000000000000000000021e19e0c9bab2400000000000000000000000000000365084b05fa7d5028346bd21d842ed0601bab5b80000000000000000000000006b3595068778dd592e39a122f4f5a5cf09c90fe200000000000000000000000000000000000000000000021b5ae39aa321200000000000000000000000000000000000000000000000000219bcaa16d86660000000000000000000000000000047e2d28169738039755586743e2dfcf3bd643f860000000000000000000000000000000000000000000000000000000000000180000000000000000000000000365084b05fa7d5028346bd21d842ed0601bab5b80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000070010205005501010203020102030001010403001eff00000000000000000000004ebdf703948ddcea3b11f675b4d1fba9d2414a14d533a949740bb3306d119cc777fa900ba034cd52c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2795065dcc9f64b5614c407a6efdc400da6221fb000000000000000000000000000000000";

        swapAction.inputToken = address(0);

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InputTokenError.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwapUnpackCheckCallDataRevert__InputAmountError() public {
        recipient = address(0x47E2D28169738039755586743E2dfCF3bd643f86);
        swapAction.inputToken = 0xD533a949740bb3306d119CC777fa900bA034cd52;
        swapAction.inputAmount = 1000000000;
        swapAction.outputToken = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
        swapAction.target = odosRouterV3;
        // Generate from Odos api.
        swapAction
            .call = hex"30f80b4c000000000000000000000000d533a949740bb3306d119cc777fa900ba034cd5200000000000000000000000000000000000000000000021e19e0c9bab2400000000000000000000000000000365084b05fa7d5028346bd21d842ed0601bab5b80000000000000000000000006b3595068778dd592e39a122f4f5a5cf09c90fe200000000000000000000000000000000000000000000021b5ae39aa321200000000000000000000000000000000000000000000000000219bcaa16d86660000000000000000000000000000047e2d28169738039755586743e2dfcf3bd643f860000000000000000000000000000000000000000000000000000000000000180000000000000000000000000365084b05fa7d5028346bd21d842ed0601bab5b80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000070010205005501010203020102030001010403001eff00000000000000000000004ebdf703948ddcea3b11f675b4d1fba9d2414a14d533a949740bb3306d119cc777fa900ba034cd52c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2795065dcc9f64b5614c407a6efdc400da6221fb000000000000000000000000000000000";

        swapAction.inputAmount = 0;

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InputAmountError.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwapUnpackCheckCallDataRevert__OutputTokenError() public {
        recipient = address(0x47E2D28169738039755586743E2dfCF3bd643f86);
        swapAction.inputToken = 0xD533a949740bb3306d119CC777fa900bA034cd52;
        swapAction.inputAmount = 10000000000000000000000;
        swapAction.outputToken = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        swapAction.target = odosRouterV3;
        // Generate from Odos api.
        swapAction
            .call = hex"30f80b4c000000000000000000000000d533a949740bb3306d119cc777fa900ba034cd5200000000000000000000000000000000000000000000021e19e0c9bab2400000000000000000000000000000365084b05fa7d5028346bd21d842ed0601bab5b80000000000000000000000006b3595068778dd592e39a122f4f5a5cf09c90fe200000000000000000000000000000000000000000000021b5ae39aa321200000000000000000000000000000000000000000000000000219bcaa16d86660000000000000000000000000000047e2d28169738039755586743e2dfcf3bd643f860000000000000000000000000000000000000000000000000000000000000180000000000000000000000000365084b05fa7d5028346bd21d842ed0601bab5b80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000070010205005501010203020102030001010403001eff00000000000000000000004ebdf703948ddcea3b11f675b4d1fba9d2414a14d533a949740bb3306d119cc777fa900ba034cd52c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2795065dcc9f64b5614c407a6efdc400da6221fb000000000000000000000000000000000";

        swapAction.outputToken = address(0);

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__OutputTokenError.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwapUnpackCheckCallDataSuccess() public {
        recipient = address(0x47E2D28169738039755586743E2dfCF3bd643f86);
        swapAction.inputToken = 0xD533a949740bb3306d119CC777fa900bA034cd52;
        swapAction.inputAmount = 10000000000000000000000;
        swapAction.outputToken = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
        swapAction.target = odosRouterV3;
        // Generate from Odos api.
        swapAction
            .call = hex"30f80b4c000000000000000000000000d533a949740bb3306d119cc777fa900ba034cd5200000000000000000000000000000000000000000000021e19e0c9bab2400000000000000000000000000000365084b05fa7d5028346bd21d842ed0601bab5b80000000000000000000000006b3595068778dd592e39a122f4f5a5cf09c90fe200000000000000000000000000000000000000000000021b5ae39aa321200000000000000000000000000000000000000000000000000219bcaa16d86660000000000000000000000000000047e2d28169738039755586743e2dfcf3bd643f860000000000000000000000000000000000000000000000000000000000000180000000000000000000000000365084b05fa7d5028346bd21d842ed0601bab5b80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000070010205005501010203020102030001010403001eff00000000000000000000004ebdf703948ddcea3b11f675b4d1fba9d2414a14d533a949740bb3306d119cc777fa900ba034cd52c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2795065dcc9f64b5614c407a6efdc400da6221fb000000000000000000000000000000000";

        checker.checkCalldata(swapAction, recipient);
    }

    function testSwap_fail_executorMismatch() public {
        recipient = address(0x47E2D28169738039755586743E2dfCF3bd643f86);
        swapAction.inputToken = 0xD533a949740bb3306d119CC777fa900bA034cd52;
        swapAction.inputAmount = 1e18;
        swapAction.outputToken = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
        swapAction.target = odosRouterV3;

        IOdosRouterV3.swapTokenInfo memory info = IOdosRouterV3.swapTokenInfo({
            inputToken: swapAction.inputToken,
            inputAmount: swapAction.inputAmount,
            inputReceiver: address(0x1), // placeholder receiver
            outputToken: swapAction.outputToken,
            outputQuote: 0,
            outputMin: 1,
            outputReceiver: recipient
        });
        bytes memory path = hex"01"; // Placeholder path
        address vitalik = address(0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045);
        IOdosRouterV3.swapReferralInfo memory ref = IOdosRouterV3
            .swapReferralInfo({ code: 0, fee: 0, feeRecipient: address(0) });

        swapAction.call = abi.encodeWithSelector(
            IOdosRouterV3.swap.selector,
            info,
            path,
            vitalik, // wrong executor
            ref
        );

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwap_fail_emptyPath() public {
        recipient = address(0x47E2D28169738039755586743E2dfCF3bd643f86);
        swapAction.inputToken = 0xD533a949740bb3306d119CC777fa900bA034cd52;
        swapAction.inputAmount = 1e18;
        swapAction.outputToken = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
        swapAction.target = odosRouterV3;

        IOdosRouterV3.swapTokenInfo memory info = IOdosRouterV3.swapTokenInfo({
            inputToken: swapAction.inputToken,
            inputAmount: swapAction.inputAmount,
            inputReceiver: address(0x1), // placeholder receiver
            outputToken: swapAction.outputToken,
            outputQuote: 0,
            outputMin: 1,
            outputReceiver: recipient
        });
        bytes memory path = hex""; // Empty path
        IOdosRouterV3.swapReferralInfo memory ref = IOdosRouterV3
            .swapReferralInfo({ code: 0, fee: 0, feeRecipient: address(0) });

        swapAction.call = abi.encodeWithSelector(
            IOdosRouterV3.swap.selector,
            info,
            path,
            odosExecutor,
            ref
        );

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidFuncSig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwap_fail_nonZeroReferral() public {
        recipient = address(0x47E2D28169738039755586743E2dfCF3bd643f86);
        swapAction.inputToken = 0xD533a949740bb3306d119CC777fa900bA034cd52;
        swapAction.inputAmount = 1e18;
        swapAction.outputToken = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
        swapAction.target = odosRouterV3;

        IOdosRouterV3.swapTokenInfo memory info = IOdosRouterV3.swapTokenInfo({
            inputToken: swapAction.inputToken,
            inputAmount: swapAction.inputAmount,
            inputReceiver: address(0x1), // placeholder receiver
            outputToken: swapAction.outputToken,
            outputQuote: 0,
            outputMin: 1,
            outputReceiver: recipient
        });
        bytes memory path = hex"01"; // Placeholder path
        IOdosRouterV3.swapReferralInfo memory ref = IOdosRouterV3
            .swapReferralInfo({ code: 1, fee: 0, feeRecipient: address(0) });

        swapAction.call = abi.encodeWithSelector(
            IOdosRouterV3.swap.selector,
            info,
            path,
            odosExecutor,
            ref
        );

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__ReferralError.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwap_success_validExecutorPathZeroReferral() public {
        recipient = address(0x47E2D28169738039755586743E2dfCF3bd643f86);
        swapAction.inputToken = 0xD533a949740bb3306d119CC777fa900bA034cd52;
        swapAction.inputAmount = 1e18;
        swapAction.outputToken = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
        swapAction.target = odosRouterV3;

        IOdosRouterV3.swapTokenInfo memory info = IOdosRouterV3.swapTokenInfo({
            inputToken: swapAction.inputToken,
            inputAmount: swapAction.inputAmount,
            inputReceiver: address(0x1), // placeholder receiver
            outputToken: swapAction.outputToken,
            outputQuote: 0,
            outputMin: 1,
            outputReceiver: recipient
        });
        bytes memory path = hex"01"; // Placeholder path
        address executor = odosExecutor;
        IOdosRouterV3.swapReferralInfo memory ref = IOdosRouterV3
            .swapReferralInfo({ code: 0, fee: 0, feeRecipient: address(0) });

        swapAction.call = abi.encodeWithSelector(
            IOdosRouterV3.swap.selector,
            info,
            path,
            executor,
            ref
        );

        checker.checkCalldata(swapAction, recipient);
    }

    function testSwap_fail_zeroMinOut() public {
        recipient = address(0x47E2D28169738039755586743E2dfCF3bd643f86);
        swapAction.inputToken = 0xD533a949740bb3306d119CC777fa900bA034cd52;
        swapAction.inputAmount = 1e18;
        swapAction.outputToken = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
        swapAction.target = odosRouterV3;

        IOdosRouterV3.swapTokenInfo memory info = IOdosRouterV3.swapTokenInfo({
            inputToken: swapAction.inputToken,
            inputAmount: swapAction.inputAmount,
            inputReceiver: address(0x1),
            outputToken: swapAction.outputToken,
            outputQuote: 0,
            outputMin: 0,
            outputReceiver: recipient
        });
        IOdosRouterV3.swapReferralInfo memory ref = IOdosRouterV3
            .swapReferralInfo({ code: 0, fee: 0, feeRecipient: address(0) });

        swapAction.call = abi.encodeWithSelector(
            IOdosRouterV3.swap.selector,
            info,
            hex"01",
            odosExecutor,
            ref
        );

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidMinOut.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwap_fail_invalidNativeInputToken() public {
        address invalidNative = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        recipient = address(0x47E2D28169738039755586743E2dfCF3bd643f86);

        swapAction.inputToken = invalidNative; // invalid
        swapAction.inputAmount = 1e18;
        swapAction.outputToken = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
        swapAction.target = odosRouterV3;

        IOdosRouterV3.swapTokenInfo memory info = IOdosRouterV3.swapTokenInfo({
            inputToken: swapAction.inputToken,
            inputAmount: swapAction.inputAmount,
            inputReceiver: address(0x1),
            outputToken: swapAction.outputToken,
            outputQuote: 0,
            outputMin: 0,
            outputReceiver: recipient
        });
        bytes memory path = hex"01";
        IOdosRouterV3.swapReferralInfo memory ref = IOdosRouterV3
            .swapReferralInfo({ code: 0, fee: 0, feeRecipient: address(0) });

        swapAction.call = abi.encodeWithSelector(
            IOdosRouterV3.swap.selector,
            info,
            path,
            odosExecutor,
            ref
        );

        vm.expectRevert(
            OdosV3CalldataChecker
                .OdosCalldataChecker__InvalidNativeTokenAddress
                .selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwap_fail_invalidNativeOutputToken() public {
        address invalidNative = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        recipient = address(0x47E2D28169738039755586743E2dfCF3bd643f86);

        swapAction.inputToken = 0xD533a949740bb3306d119CC777fa900bA034cd52;
        swapAction.inputAmount = 1e18;
        swapAction.outputToken = invalidNative; // Invalid
        swapAction.target = odosRouterV3;

        IOdosRouterV3.swapTokenInfo memory info = IOdosRouterV3.swapTokenInfo({
            inputToken: swapAction.inputToken,
            inputAmount: swapAction.inputAmount,
            inputReceiver: address(0x1),
            outputToken: swapAction.outputToken,
            outputQuote: 0,
            outputMin: 0,
            outputReceiver: recipient
        });
        bytes memory path = hex"01";
        IOdosRouterV3.swapReferralInfo memory ref = IOdosRouterV3
            .swapReferralInfo({ code: 0, fee: 0, feeRecipient: address(0) });

        swapAction.call = abi.encodeWithSelector(
            IOdosRouterV3.swap.selector,
            info,
            path,
            odosExecutor,
            ref
        );

        vm.expectRevert(
            OdosV3CalldataChecker
                .OdosCalldataChecker__InvalidNativeTokenAddress
                .selector
        );
        checker.checkCalldata(swapAction, recipient);
    }
}
