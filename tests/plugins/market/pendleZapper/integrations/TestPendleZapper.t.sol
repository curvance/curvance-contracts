// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {IPendleRouter} from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import {IPendlePTOracle} from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import {PendleZapper} from "contracts/plugins/market/PendleZapper.sol";
import {BaseSwapChecker} from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import {PendleLPTokenAdaptor} from "contracts/oracles/adaptors/pendle/PendleLPTokenAdaptor.sol";
import {PendleLPCToken} from "contracts/market/token/PendleLPCToken.sol";
import {PendleLib} from "contracts/libraries/PendleLib.sol";

import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {AccountSnapshot, ICToken} from "contracts/interfaces/ICToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IPluginDelegable} from "contracts/interfaces/IPluginDelegable.sol";
import {BaseZapper} from "contracts/plugins/BaseZapper.sol";

import {MockCalldataChecker} from "contracts/mocks/MockCalldataChecker.sol";
import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";

contract TestPendleZapper is TestBaseMarketIsolated {
    address internal _PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address internal _PENDLE_LP_STETH = 0xD0354D4e7bCf345fB117cabe41aCaDb724eccCa2;
    address internal _CHAINLINK_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address internal _PT_ORACLE = 0x14030836AEc15B2ad48bB097bd57032559339c92;
    address internal _PT_STETH = 0x7758896b6AC966BbABcf143eFA963030f17D3EdF;
    address internal _LP_STETH = 0xD0354D4e7bCf345fB117cabe41aCaDb724eccCa2;

    bool internal _IS_PT = false;

    PendleLPTokenAdaptor public adaptor;
    PendleLPCToken public pendleCTokenSTETH;
    MockPendlePostSwapTarget internal postSwapTarget;
    SwapperLibHarness internal swapperHarness;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork(20287400);
        _init();

        chainlinkAdaptor.addAsset(_STETH, true, _CHAINLINK_STETH_USD, 0);
        // oracleManager.addAssetPriceFeed(_STETH, address(chainlinkAdaptor));

        adaptor = new PendleLPTokenAdaptor(ICentralRegistry(address(centralRegistry)), IPendlePTOracle(_PT_ORACLE));
        PendleLPTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.twapDuration = 12;
        assetConfig.quoteAsset = _STETH;
        assetConfig.pt = _PT_STETH;
        assetConfig.quoteAssetDecimals = 18;
        adaptor.addAsset(_LP_STETH, assetConfig);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPricingAdaptor(_LP_STETH, address(adaptor), 100, 50, 100, 50);

        postSwapTarget = new MockPendlePostSwapTarget();
        swapperHarness = new SwapperLibHarness();
        centralRegistry.setExternalCalldataChecker(
            address(postSwapTarget),
            address(new MockCalldataChecker(address(postSwapTarget)))
        );
        _prepareDAI(address(postSwapTarget), 1_000_000e18);
        _prepareUSDC(address(postSwapTarget), 1_000_000e6);

        pendleCTokenSTETH = new PendleLPCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_LP_STETH),
            address(marketManagerIsolated),
            IPendleRouter(_PENDLE_ROUTER),
            1 days
        );
        oracleManager.addCTokenSupport(address(pendleCTokenSTETH));

        _prepareUSDC(address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        deal(_LP_STETH, address(this), 1 ether);
        IERC20(_LP_STETH).approve(address(pendleCTokenSTETH), 1 ether);

        marketManagerIsolated.listTokens(address(pendleCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(pendleCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigLowValues(address(borrowableCUSDC), 100_000e18, 100_000e18);
    }

    function testEnterPendle() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.startPrank(user1);
        pendleZapper.enterPendle{value: ethAmount}(
            address(pendleCTokenSTETH),
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(address(0), ethAmount, _PENDLE_LP_STETH, 1, true),
            new SwapperLib.Swap[](0),
            1.2 ether,
            false,
            user1
        );

        vm.stopPrank();

        assertEq(user1.balance, 0);
        assertGt(IERC20(address(pendleCTokenSTETH)).balanceOf(user1), 0);
    }

    function test_pendleZapper_fail_enterPendleErc20WithMsgValue() public {
        vm.deal(user1, 1);

        // Dummy values, we are reverting fairly early in the function.
        PendleLib.PendleAction memory action;
        action.approx.guessMin = 1;
        action.approx.guessMax = 1;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 1;
        action.approx.eps = 1;

        vm.startPrank(user1);

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);

        pendleZapper.enterPendle{value: 1}( // Incorrectly attach 1 wei to the call
            address(pendleCTokenSTETH),
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(_LP_STETH, 1, _PENDLE_LP_STETH, 0, false),
            new SwapperLib.Swap[](0),
            1,
            false,
            user1
        );

        vm.stopPrank();
    }

    function testEnterPendle_fail_unlistedCTokenBeforeAssetLookup() public {
        address fakeCToken = address(0xBEEF);

        vm.mockCall(
            fakeCToken,
            abi.encodeWithSelector(ICToken.marketManager.selector),
            abi.encode(address(marketManagerIsolated))
        );
        vm.mockCallRevert(
            fakeCToken,
            abi.encodeWithSelector(ICToken.asset.selector),
            "asset called"
        );

        PendleLib.PendleAction memory action;

        vm.expectRevert(BaseZapper.BaseZapper__Unauthorized.selector);
        pendleZapper.enterPendle(
            fakeCToken,
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(address(0), 1, _PENDLE_LP_STETH, 1, true),
            new SwapperLib.Swap[](0),
            1,
            false,
            user1
        );
    }

    function testEnterPendle_fail_ZeroReceiver() public {
        PendleLib.PendleAction memory action;

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        pendleZapper.enterPendle(
            address(pendleCTokenSTETH),
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(address(0), 1, _PENDLE_LP_STETH, 1, true),
            new SwapperLib.Swap[](0),
            1,
            false,
            address(0)
        );
    }

    function testEnterPendle_fail_ZeroExpectedShares() public {
        PendleLib.PendleAction memory action;

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        pendleZapper.enterPendle(
            address(pendleCTokenSTETH),
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(address(0), 1, _PENDLE_LP_STETH, 1, true),
            new SwapperLib.Swap[](0),
            0,
            false,
            user1
        );
    }

    function testEnterPendle_fail_PrePendleSwapSafeSlippage() public {
        uint256 inputAmount = 100e18;
        _prepareDAI(user1, inputAmount);

        PendleLib.PendleAction memory action;

        SwapperLib.Swap[] memory swapActions = new SwapperLib.Swap[](1);
        swapActions[0].inputToken = _DAI_ADDRESS;
        swapActions[0].inputAmount = inputAmount;
        swapActions[0].outputToken = _USDC_ADDRESS;
        swapActions[0].target = address(postSwapTarget);
        swapActions[0].slippage = 0;
        swapActions[0].call = abi.encodeWithSelector(
            MockPendlePostSwapTarget.swap.selector,
            _DAI_ADDRESS,
            _USDC_ADDRESS,
            inputAmount,
            99e6
        );

        vm.startPrank(user1);
        dai.approve(address(pendleZapper), inputAmount);

        vm.expectPartialRevert(SwapperLib.SwapperLib__Slippage.selector);
        pendleZapper.enterPendle(
            address(pendleCTokenSTETH),
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(_DAI_ADDRESS, inputAmount, _PENDLE_LP_STETH, 1, false),
            swapActions,
            1,
            false,
            user1
        );
        vm.stopPrank();
    }

    function testExitPendle() public {
        deal(_PENDLE_LP_STETH, user1, 0.05 ether);
        IERC20(_PENDLE_LP_STETH).approve(address(pendleZapper), 0.05 ether);

        uint256 withdrawAmount = IERC20(_PENDLE_LP_STETH).balanceOf(user1);

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.startPrank(user1);
        IERC20(_PENDLE_LP_STETH).approve(address(pendleZapper), withdrawAmount);
        pendleZapper.exitPendle(
            _STETH,
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(_PENDLE_LP_STETH, withdrawAmount, _STETH, 1, false),
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();

        assertGt(IERC20(_STETH).balanceOf(user1), 0);
        // assertGt(IERC20(_USDC).balanceOf(user1), 0);
        assertEq(IERC20(_PENDLE_LP_STETH).balanceOf(user1), 0);
    }

    function testExitPendle_fail_ZeroReceiver() public {
        PendleLib.PendleAction memory action;

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        pendleZapper.exitPendle(
            _STETH,
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(_PENDLE_LP_STETH, 1, _STETH, 1, false),
            new SwapperLib.Swap[](0),
            address(0)
        );
    }

    function testExitPendle_fail_TerminalMinimumOutIsZero() public {
        deal(_PENDLE_LP_STETH, user1, 0.05 ether);

        uint256 withdrawAmount = IERC20(_PENDLE_LP_STETH).balanceOf(user1);

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.startPrank(user1);
        IERC20(_PENDLE_LP_STETH).approve(address(pendleZapper), withdrawAmount);

        vm.expectRevert(PendleZapper.PendleZapper__SlippageError.selector);
        pendleZapper.exitPendle(
            _STETH,
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(_PENDLE_LP_STETH, withdrawAmount, _STETH, 0, false),
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();
    }

    function testExitPendle_fail_TerminalMinimumOutTooHigh() public {
        deal(_PENDLE_LP_STETH, user1, 0.05 ether);

        uint256 withdrawAmount = IERC20(_PENDLE_LP_STETH).balanceOf(user1);

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.startPrank(user1);
        IERC20(_PENDLE_LP_STETH).approve(address(pendleZapper), withdrawAmount);

        vm.expectRevert(PendleZapper.PendleZapper__SlippageError.selector);
        pendleZapper.exitPendle(
            _STETH,
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(_PENDLE_LP_STETH, withdrawAmount, _STETH, type(uint256).max, false),
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();
    }

    function testExitPendle_fail_PostPendleSwapSafeSlippage() public {
        deal(_PENDLE_LP_STETH, user1, 0.05 ether);

        uint256 withdrawAmount = IERC20(_PENDLE_LP_STETH).balanceOf(user1);

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        SwapperLib.Swap[] memory swapActions = new SwapperLib.Swap[](1);
        swapActions[0].inputToken = _STETH;
        swapActions[0].inputAmount = 0.001 ether;
        swapActions[0].outputToken = _DAI_ADDRESS;
        swapActions[0].target = address(postSwapTarget);
        swapActions[0].slippage = 0;
        swapActions[0].call = abi.encodeWithSelector(
            MockPendlePostSwapTarget.swap.selector,
            _STETH,
            _DAI_ADDRESS,
            0.001 ether,
            0.001 ether
        );

        vm.startPrank(user1);
        IERC20(_PENDLE_LP_STETH).approve(address(pendleZapper), withdrawAmount);

        vm.expectPartialRevert(SwapperLib.SwapperLib__Slippage.selector);
        pendleZapper.exitPendle(
            _STETH,
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(_PENDLE_LP_STETH, withdrawAmount, _DAI_ADDRESS, 1, false),
            swapActions,
            user1
        );
        vm.stopPrank();
    }

    function testEnterPendleWithCToken() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.startPrank(user1);
        pendleZapper.enterPendle{value: ethAmount}(
            address(pendleCTokenSTETH),
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(address(0), ethAmount, _PENDLE_LP_STETH, 1, true),
            new SwapperLib.Swap[](0),
            1.2 ether,
            false,
            user1
        );

        vm.stopPrank();

        AccountSnapshot memory pendleCTokenSTETHSnapshot = pendleCTokenSTETH.getSnapshot(user1);

        assertApproxEqRel(pendleCTokenSTETH.balanceOf(user1), 1.24 ether, 0.01 ether);
        assertEq(pendleCTokenSTETHSnapshot.debtBalance, 0);
        assertEq(user1.balance, 0);
    }

    function testSwapperLibEnterPendleE2EFinalOutputIsCTokenShares() public {
        uint256 ethAmount = 3 ether;
        uint256 expectedShares = 1.2 ether;
        vm.deal(address(swapperHarness), ethAmount);

        PendleLib.PendleAction memory action = _defaultPendleAction();
        SwapperLib.Swap memory swapAction = SwapperLib.Swap({
            inputToken: address(0),
            inputAmount: ethAmount,
            outputToken: address(pendleCTokenSTETH),
            target: address(pendleZapper),
            slippage: 0,
            call: abi.encodeWithSelector(
                PendleZapper.enterPendle.selector,
                address(pendleCTokenSTETH),
                _PENDLE_ROUTER,
                _IS_PT,
                action,
                PendleZapper.ZapAction(address(0), ethAmount, _PENDLE_LP_STETH, 1, true),
                new SwapperLib.Swap[](0),
                expectedShares,
                false,
                address(swapperHarness)
            )
        });

        uint256 cTokenBefore = pendleCTokenSTETH.balanceOf(address(swapperHarness));
        uint256 pendleLpBefore = IERC20(_PENDLE_LP_STETH).balanceOf(address(swapperHarness));

        uint256 outAmount = swapperHarness.swapUnsafe(ICentralRegistry(address(centralRegistry)), swapAction);

        uint256 cTokenDelta = pendleCTokenSTETH.balanceOf(address(swapperHarness)) - cTokenBefore;
        assertEq(outAmount, cTokenDelta);
        assertGe(outAmount, expectedShares);
        assertEq(IERC20(_PENDLE_LP_STETH).balanceOf(address(swapperHarness)), pendleLpBefore);
        assertEq(address(swapperHarness).balance, 0);
    }

    function testSwapperLibEnterPendleRejectsPendleOutputAsFinalOutput() public {
        uint256 ethAmount = 3 ether;
        uint256 expectedShares = 1.2 ether;
        vm.deal(address(swapperHarness), ethAmount);

        PendleLib.PendleAction memory action = _defaultPendleAction();
        SwapperLib.Swap memory swapAction = SwapperLib.Swap({
            inputToken: address(0),
            inputAmount: ethAmount,
            outputToken: _PENDLE_LP_STETH,
            target: address(pendleZapper),
            slippage: 0,
            call: abi.encodeWithSelector(
                PendleZapper.enterPendle.selector,
                address(pendleCTokenSTETH),
                _PENDLE_ROUTER,
                _IS_PT,
                action,
                PendleZapper.ZapAction(address(0), ethAmount, _PENDLE_LP_STETH, 1, true),
                new SwapperLib.Swap[](0),
                expectedShares,
                false,
                address(swapperHarness)
            )
        });

        vm.expectRevert(BaseSwapChecker.CalldataChecker__OutputTokenError.selector);
        swapperHarness.swapUnsafe(ICentralRegistry(address(centralRegistry)), swapAction);
    }

    function testSwapperLibRedeemAndExitE2EInputIsCTokenShares() public {
        uint256 shares = _enterPendleThroughSwapper();
        uint256 zapInputAmount = shares - 1;
        swapperHarness.setDelegateApproval(
            IPluginDelegable(address(pendleCTokenSTETH)),
            address(pendleZapper),
            true
        );

        PendleLib.PendleAction memory action = _defaultPendleAction();
        BaseZapper.RedeemAction memory redeemAction = BaseZapper.RedeemAction({
            cToken: address(pendleCTokenSTETH),
            shares: shares,
            forceRedeemCollateral: false
        });
        SwapperLib.Swap memory swapAction = _redeemAndExitSwapAction(action, redeemAction, zapInputAmount, shares);

        uint256 cTokenBefore = pendleCTokenSTETH.balanceOf(address(swapperHarness));
        uint256 stEthBefore = IERC20(_STETH).balanceOf(address(swapperHarness));

        uint256 outAmount = swapperHarness.swapUnsafe(ICentralRegistry(address(centralRegistry)), swapAction);

        assertEq(cTokenBefore - pendleCTokenSTETH.balanceOf(address(swapperHarness)), shares);
        assertEq(outAmount, IERC20(_STETH).balanceOf(address(swapperHarness)) - stEthBefore);
        assertGt(outAmount, 0);
    }

    function testSwapperLibRedeemAndExitRejectsZapInputAmountAsSwapInput() public {
        uint256 shares = _enterPendleThroughSwapper();
        uint256 zapInputAmount = shares - 1;

        PendleLib.PendleAction memory action = _defaultPendleAction();
        BaseZapper.RedeemAction memory redeemAction = BaseZapper.RedeemAction({
            cToken: address(pendleCTokenSTETH),
            shares: shares,
            forceRedeemCollateral: false
        });
        SwapperLib.Swap memory swapAction = _redeemAndExitSwapAction(
            action,
            redeemAction,
            zapInputAmount,
            zapInputAmount
        );

        vm.expectRevert(BaseSwapChecker.CalldataChecker__InputAmountError.selector);
        swapperHarness.swapUnsafe(ICentralRegistry(address(centralRegistry)), swapAction);
    }

    function testEnterPendle_fail_InsufficientExpectedShares() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.startPrank(user1);
        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        pendleZapper.enterPendle{value: ethAmount}(
            address(pendleCTokenSTETH),
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(address(0), ethAmount, _PENDLE_LP_STETH, 1, true),
            new SwapperLib.Swap[](0),
            type(uint256).max,
            false,
            user1
        );
        vm.stopPrank();
    }

    function testEnterPendleWithCTokenWithCollateralize() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.startPrank(user1);
        pendleCTokenSTETH.setDelegateApproval(address(pendleZapper), true);

        pendleZapper.enterPendle{value: ethAmount}(
            address(pendleCTokenSTETH),
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(address(0), ethAmount, _PENDLE_LP_STETH, 1, true),
            new SwapperLib.Swap[](0),
            1.2 ether,
            true,
            user1
        );

        vm.stopPrank();

        AccountSnapshot memory pendleCTokenSTETHSnapshot = pendleCTokenSTETH.getSnapshot(user1);

        assertApproxEqRel(pendleCTokenSTETH.balanceOf(user1), 1.24 ether, 0.01 ether);
        assertEq(pendleCTokenSTETHSnapshot.debtBalance, 0);
        assertEq(user1.balance, 0);
    }

    function testEnterPendleWithDelegation() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user2, ethAmount);

        vm.startPrank(user1);
        pendleCTokenSTETH.setDelegateApproval(user2, true);
        pendleCTokenSTETH.setDelegateApproval(address(pendleZapper), true);
        vm.stopPrank();

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.startPrank(user2);
        pendleZapper.enterPendle{value: ethAmount}(
            address(pendleCTokenSTETH),
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            PendleZapper.ZapAction(address(0), ethAmount, _PENDLE_LP_STETH, 1, true),
            new SwapperLib.Swap[](0),
            1.2 ether,
            true,
            user1
        );

        vm.stopPrank();

        AccountSnapshot memory pendleCTokenSTETHSnapshot = pendleCTokenSTETH.getSnapshot(user1);

        assertApproxEqRel(pendleCTokenSTETH.balanceOf(user1), 1.24 ether, 0.01 ether);
        assertEq(pendleCTokenSTETHSnapshot.debtBalance, 0);
        assertEq(user2.balance, 0);
    }

    function testRedeemAndExitPendle() public {
        testEnterPendleWithCTokenWithCollateralize();

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(pendleCTokenSTETH);
        redeemAction.shares = 1.24 ether;
        redeemAction.forceRedeemCollateral = false;

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.warp(marketManagerIsolated.accountAssets(user1) + marketManagerIsolated.MIN_HOLD_PERIOD());

        vm.startPrank(user1);
        pendleCTokenSTETH.setDelegateApproval(address(pendleZapper), true);

        IERC20(_PENDLE_LP_STETH).approve(address(pendleZapper), 3 ether);
        pendleZapper.redeemAndExitPendle(
            _STETH,
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            redeemAction,
            PendleZapper.ZapAction(_PENDLE_LP_STETH, 1.24 ether, _STETH, 1, false),
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();

        assertApproxEqRel(IERC20(_STETH).balanceOf(user1), 2.6 ether, 0.1 ether);
    }

    function testRedeemAndExitPendle_fail_ZeroReceiver() public {
        BaseZapper.RedeemAction memory redeemAction;
        PendleLib.PendleAction memory action;

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        pendleZapper.redeemAndExitPendle(
            _STETH,
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            redeemAction,
            PendleZapper.ZapAction(_PENDLE_LP_STETH, 1 ether, _STETH, 1, false),
            new SwapperLib.Swap[](0),
            address(0)
        );
    }

    function testRedeemAndExitPendle_fail_TerminalMinimumOutIsZero() public {
        testEnterPendleWithCTokenWithCollateralize();

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(pendleCTokenSTETH);
        redeemAction.shares = 1.24 ether;
        redeemAction.forceRedeemCollateral = false;

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.warp(marketManagerIsolated.accountAssets(user1) + marketManagerIsolated.MIN_HOLD_PERIOD());

        vm.startPrank(user1);
        pendleCTokenSTETH.setDelegateApproval(address(pendleZapper), true);
        IERC20(_PENDLE_LP_STETH).approve(address(pendleZapper), 3 ether);

        vm.expectRevert(PendleZapper.PendleZapper__SlippageError.selector);
        pendleZapper.redeemAndExitPendle(
            _STETH,
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            redeemAction,
            PendleZapper.ZapAction(_PENDLE_LP_STETH, 1.24 ether, _STETH, 0, false),
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();
    }

    function testRedeemAndExitPendle_fail_TerminalMinimumOutTooHigh() public {
        testEnterPendleWithCTokenWithCollateralize();

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(pendleCTokenSTETH);
        redeemAction.shares = 1.24 ether;
        redeemAction.forceRedeemCollateral = false;

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.warp(marketManagerIsolated.accountAssets(user1) + marketManagerIsolated.MIN_HOLD_PERIOD());

        vm.startPrank(user1);
        pendleCTokenSTETH.setDelegateApproval(address(pendleZapper), true);
        IERC20(_PENDLE_LP_STETH).approve(address(pendleZapper), 3 ether);

        vm.expectRevert(PendleZapper.PendleZapper__SlippageError.selector);
        pendleZapper.redeemAndExitPendle(
            _STETH,
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            redeemAction,
            PendleZapper.ZapAction(_PENDLE_LP_STETH, 1.24 ether, _STETH, type(uint256).max, false),
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();
    }

    function _defaultPendleAction() internal pure returns (PendleLib.PendleAction memory action) {
        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;
    }

    function _enterPendleThroughSwapper() internal returns (uint256 shares) {
        uint256 ethAmount = 3 ether;
        uint256 expectedShares = 1.2 ether;
        vm.deal(address(swapperHarness), ethAmount);

        PendleLib.PendleAction memory action = _defaultPendleAction();
        SwapperLib.Swap memory swapAction = SwapperLib.Swap({
            inputToken: address(0),
            inputAmount: ethAmount,
            outputToken: address(pendleCTokenSTETH),
            target: address(pendleZapper),
            slippage: 0,
            call: abi.encodeWithSelector(
                PendleZapper.enterPendle.selector,
                address(pendleCTokenSTETH),
                _PENDLE_ROUTER,
                _IS_PT,
                action,
                PendleZapper.ZapAction(address(0), ethAmount, _PENDLE_LP_STETH, 1, true),
                new SwapperLib.Swap[](0),
                expectedShares,
                false,
                address(swapperHarness)
            )
        });

        shares = swapperHarness.swapUnsafe(ICentralRegistry(address(centralRegistry)), swapAction);
    }

    function _redeemAndExitSwapAction(
        PendleLib.PendleAction memory action,
        BaseZapper.RedeemAction memory redeemAction,
        uint256 zapInputAmount,
        uint256 swapInputAmount
    ) internal view returns (SwapperLib.Swap memory swapAction) {
        swapAction = SwapperLib.Swap({
            inputToken: address(pendleCTokenSTETH),
            inputAmount: swapInputAmount,
            outputToken: _STETH,
            target: address(pendleZapper),
            slippage: 0,
            call: abi.encodeWithSelector(
                PendleZapper.redeemAndExitPendle.selector,
                _STETH,
                _PENDLE_ROUTER,
                _IS_PT,
                action,
                redeemAction,
                PendleZapper.ZapAction(_PENDLE_LP_STETH, zapInputAmount, _STETH, 1, false),
                new SwapperLib.Swap[](0),
                address(swapperHarness)
            )
        });
    }
}

contract MockPendlePostSwapTarget {
    function swap(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    ) external {
        IERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount);
        IERC20(outputToken).transfer(msg.sender, outputAmount);
    }
}

contract SwapperLibHarness {
    receive() external payable {}

    function setDelegateApproval(
        IPluginDelegable token,
        address delegate,
        bool isApproved
    ) external {
        token.setDelegateApproval(delegate, isApproved);
    }

    function swapUnsafe(
        ICentralRegistry centralRegistry,
        SwapperLib.Swap memory swapAction
    ) external returns (uint256) {
        return SwapperLib._swapUnsafe(centralRegistry, swapAction);
    }
}
