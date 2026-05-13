// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {OptimizerZapper} from "contracts/plugins/market/OptimizerZapper.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";

import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {DynamicIRM} from "contracts/market/DynamicIRM.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {
    IUniswapV3Router
} from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";

import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";
import {MockCalldataChecker} from "contracts/mocks/MockCalldataChecker.sol";

contract TestOptimizerZapper is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    OptimizerZapper public optimizerZapper;
    LendingOptimizer public optimizer;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        // Deploy OptimizerZapper.
        optimizerZapper = new OptimizerZapper(
            ICentralRegistry(address(centralRegistry)), _WETH_ADDRESS
        );

        // Register Uniswap V3 calldata checker.
        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        // Prepare underlying tokens for listTokens — each cToken pulls
        // 77777 of its underlying via initializeDeposits(msg.sender).
        _prepareWETH(address(this), 77777);
        _prepareUSDC(address(this), 77777);
        weth.approve(address(borrowableCWETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        // List borrowableCUSDC so market manager accepts deposits.
        // Pair with borrowableCWETH as collateral (deployed by _init()).
        marketManagerIsolated.listTokens(
            address(borrowableCWETH), address(borrowableCUSDC)
        );
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e18);
        _setCTokenConfigHighValues(address(borrowableCWETH), 100_000e18, 0);

        // Deploy LendingOptimizer with borrowableCUSDC as the sole market.
        // Must be after listTokens since _validateCToken checks isListed().
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(borrowableCUSDC);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 10000; // 100%

        optimizer = new LendingOptimizer(
            usdc,
            ICentralRegistry(address(centralRegistry)),
            cTokens,
            caps,
            0 // No performance fee for test simplicity.
        );

        // Initialize the optimizer (pulls 77777 USDC via initializeDeposits).
        _prepareUSDC(address(this), 77777);
        usdc.approve(address(optimizer), 77777);
        optimizer.initializeDeposits(address(borrowableCUSDC));

        // Seed liquidity into borrowableCUSDC so deposits have somewhere to go.
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 10_000e6);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 10_000e6);
        borrowableCUSDC.deposit(10_000e6, liquidityProvider);
        vm.stopPrank();
    }

    // ─── Happy Path ──────────────────────────────────────────────────

    function testSwapAndDeposit() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.inputAmount = ethAmount;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _USDC_ADDRESS;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(optimizerZapper);
        params.deadline = block.timestamp;
        params.amountIn = ethAmount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        vm.prank(user1);
        uint256 shares = optimizerZapper.swapAndDeposit{value: ethAmount}(
            address(optimizer), false, swapAction, 0, user1
        );

        assertEq(user1.balance, 0, "User should have spent all ETH");
        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(
            optimizer.balanceOf(user1),
            shares,
            "Balance should match returned shares"
        );
        _assertOptimizerZapperHasNoResidue(address(optimizer));
    }

    function testSwapAndDeposit_NoSwap() public {
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        uint256 expectedShares = optimizer.previewDeposit(amount);
        uint256 shares = optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 0, user1
        );
        vm.stopPrank();

        assertEq(
            shares, expectedShares, "Returned shares should match preview"
        );
        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(
            optimizer.balanceOf(user1),
            shares,
            "Balance should match returned shares"
        );
        assertEq(
            usdc.balanceOf(user1), 0, "User should have deposited all USDC"
        );
        _assertOptimizerZapperHasNoResidue(address(optimizer));
    }

    function testSwapAndDeposit_preExistingUnderlyingResidueDoesNotMintShares()
        public
    {
        uint256 residue = 25e6;
        _prepareUSDC(address(optimizerZapper), residue);

        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        uint256 expectedShares = optimizer.previewDeposit(amount);
        uint256 userSharesBefore = optimizer.balanceOf(user1);

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        uint256 shares = optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 0, user1
        );
        vm.stopPrank();

        assertEq(
            shares,
            expectedShares,
            "returned shares should ignore pre-existing residue"
        );
        assertEq(
            optimizer.balanceOf(user1) - userSharesBefore,
            shares,
            "user share delta should match returned shares"
        );
        assertEq(
            usdc.balanceOf(address(optimizerZapper)),
            residue,
            "pre-existing underlying residue should not be deposited"
        );
    }

    function testSwapAndDeposit_NoSwap_WrappedNativeInput() public {
        uint256 amount = 3 ether;
        vm.deal(user1, amount);

        address[] memory cTokens = new address[](1);
        cTokens[0] = address(borrowableCWETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 10000;

        LendingOptimizer wethOptimizer = new LendingOptimizer(
            weth, ICentralRegistry(address(centralRegistry)), cTokens, caps, 0
        );

        _prepareWETH(address(this), 77777);
        weth.approve(address(wethOptimizer), 77777);
        wethOptimizer.initializeDeposits(address(borrowableCWETH));

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _WETH_ADDRESS;

        uint256 expectedShares = wethOptimizer.previewDeposit(amount);
        vm.prank(user1);
        uint256 shares = optimizerZapper.swapAndDeposit{value: amount}(
            address(wethOptimizer), true, swapAction, 0, user1
        );

        assertEq(user1.balance, 0, "User should have spent all ETH");
        assertEq(
            shares, expectedShares, "Returned shares should match preview"
        );
        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(
            wethOptimizer.balanceOf(user1),
            shares,
            "Balance should match returned shares"
        );
        _assertOptimizerZapperHasNoResidue(address(wethOptimizer));
    }

    function testSwapAndDeposit_DifferentReceiver() public {
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        uint256 expectedShares = optimizer.previewDeposit(amount);
        uint256 shares = optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 0, user2
        );
        vm.stopPrank();

        assertEq(
            shares, expectedShares, "Returned shares should match preview"
        );
        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(
            optimizer.balanceOf(user2), shares, "Receiver should hold shares"
        );
        assertEq(optimizer.balanceOf(user1), 0, "Sender should hold no shares");
        _assertOptimizerZapperHasNoResidue(address(optimizer));
    }

    // ─── Failure Cases ───────────────────────────────────────────────

    function testSwapAndDeposit_fail_ZeroReceiver() public {
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__ExecutionError.selector
        );
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 0, address(0)
        );
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_AssetMismatch() public {
        uint256 amount = 10 ether;
        _prepareDAI(user1, amount);

        // Output is DAI but optimizer's underlying is USDC.
        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _DAI_ADDRESS;

        vm.startPrank(user1);
        dai.approve(address(optimizerZapper), amount);

        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__AssetMismatch.selector
        );
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 0, user1
        );
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_AssetMismatchBeforeExternalSwap() public {
        uint256 amount = 10 ether;
        _prepareDAI(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _WETH_ADDRESS;
        swapAction.target = address(0xBEEF);
        swapAction.call = hex"deadbeef";

        vm.startPrank(user1);
        dai.approve(address(optimizerZapper), amount);

        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__AssetMismatch.selector
        );
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 0, user1
        );
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_InsufficientShares() public {
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        // Expect revert because expectedShares is impossibly high.
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 optimizerBalanceBefore = optimizer.balanceOf(user1);
        uint256 totalAssetsBefore = optimizer.totalAssets();

        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__ExecutionError.selector
        );
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, type(uint256).max, user1
        );

        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(optimizer.balanceOf(user1), optimizerBalanceBefore);
        assertEq(optimizer.totalAssets(), totalAssetsBefore);
        _assertOptimizerZapperHasNoResidue(address(optimizer));
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_TightSwapSafeSlippage() public {
        uint256 amount = 1000e18;
        _prepareDAI(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = 0;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(optimizerZapper);
        params.deadline = block.timestamp;
        params.amountIn = amount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        vm.startPrank(user1);
        dai.approve(address(optimizerZapper), amount);

        vm.expectPartialRevert(SwapperLib.SwapperLib__Slippage.selector);
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 0, user1
        );
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_UnknownSwapTargetRollsBack() public {
        uint256 amount = 1000e18;
        _prepareDAI(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = address(0xBEEF);
        swapAction.call = hex"deadbeef";

        vm.startPrank(user1);
        dai.approve(address(optimizerZapper), amount);

        uint256 userDaiBefore = dai.balanceOf(user1);
        uint256 optimizerSharesBefore = optimizer.balanceOf(user1);
        uint256 totalAssetsBefore = optimizer.totalAssets();

        vm.expectRevert(SwapperLib.SwapperLib__UnknownCalldata.selector);
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 0, user1
        );

        assertEq(dai.balanceOf(user1), userDaiBefore);
        assertEq(optimizer.balanceOf(user1), optimizerSharesBefore);
        assertEq(optimizer.totalAssets(), totalAssetsBefore);
        _assertOptimizerZapperHasNoResidue(address(optimizer));
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_OutputSentAwayRollsBackAtMaxSlippage()
        public
    {
        uint256 amount = 1000e18;
        _prepareDAI(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = 0.999e18;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = user1;
        params.deadline = block.timestamp;
        params.amountIn = amount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        vm.startPrank(user1);
        dai.approve(address(optimizerZapper), amount);

        uint256 userDaiBefore = dai.balanceOf(user1);
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 totalAssetsBefore = optimizer.totalAssets();

        vm.expectRevert(
            abi.encodeWithSelector(
                SwapperLib.SwapperLib__Slippage.selector, 1e18
            )
        );
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 0, user1
        );

        assertEq(dai.balanceOf(user1), userDaiBefore);
        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(optimizer.totalAssets(), totalAssetsBefore);
        _assertOptimizerZapperHasNoResidue(address(optimizer));
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_MsgValueWithERC20() public {
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);
        vm.deal(user1, 1 ether);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__ExecutionError.selector
        );
        optimizerZapper.swapAndDeposit{value: 1 ether}(
            address(optimizer), false, swapAction, 0, user1
        );
        vm.stopPrank();
    }

    // ─── Multi-Market / Allocation Cap ───────────────────────────────

    function testSwapAndDeposit_fail_NativeValueMismatchRollsBack() public {
        uint256 amount = 3 ether;
        vm.deal(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.prank(user1);
        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__ExecutionError.selector
        );
        optimizerZapper.swapAndDeposit{value: amount - 1}(
            address(optimizer), false, swapAction, 0, user1
        );

        assertEq(user1.balance, amount);
        assertEq(optimizer.balanceOf(user1), 0);
        _assertOptimizerZapperHasNoResidue(address(optimizer));
    }

    function testSwapAndDeposit_TwoMarkets_ExceedsCap() public {
        // Deploy a second isolated market for borrowableCUSDC2.
        MarketManagerIsolated mm2 = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry)), 10e18, false
        );
        centralRegistry.addMarketManager(address(mm2));

        // Deploy borrowableCUSDC2 and a WETH collateral token in mm2.
        DynamicIRM irm2 = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            1000,
            100,
            100000
        );
        BorrowableCToken borrowableCUSDC2 = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            usdc,
            address(mm2),
            address(irm2)
        );
        irm2.setLinkedToken(address(borrowableCUSDC2));

        DynamicIRM irmWeth2 = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            1000,
            100,
            100000
        );
        BorrowableCToken collateralWETH2 = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            weth,
            address(mm2),
            address(irmWeth2)
        );
        irmWeth2.setLinkedToken(address(collateralWETH2));

        oracleManager.addCTokenSupport(address(borrowableCUSDC2));
        oracleManager.addCTokenSupport(address(collateralWETH2));

        // List and initialize deposits in mm2.
        _prepareWETH(address(this), 77777);
        _prepareUSDC(address(this), 77777);
        weth.approve(address(collateralWETH2), 77777);
        usdc.approve(address(borrowableCUSDC2), 77777);
        mm2.listTokens(address(collateralWETH2), address(borrowableCUSDC2));

        // Seed liquidity into borrowableCUSDC2.
        address lp2 = makeAddr("lp2");
        _prepareUSDC(lp2, 10_000e6);
        vm.startPrank(lp2);
        usdc.approve(address(borrowableCUSDC2), 10_000e6);
        borrowableCUSDC2.deposit(10_000e6, lp2);
        vm.stopPrank();

        // Deploy a fresh optimizer with two markets at 50% cap each.
        address[] memory cTokens = new address[](2);
        cTokens[0] = address(borrowableCUSDC);
        cTokens[1] = address(borrowableCUSDC2);
        uint256[] memory caps = new uint256[](2);
        caps[0] = 5000; // 50%
        caps[1] = 5000; // 50%

        LendingOptimizer optimizer2 = new LendingOptimizer(
            usdc, ICentralRegistry(address(centralRegistry)), cTokens, caps, 0
        );

        // Initialize the optimizer.
        _prepareUSDC(address(this), 77777);
        usdc.approve(address(optimizer2), 77777);
        optimizer2.initializeDeposits(address(borrowableCUSDC));

        // Deposit 1000 USDC entirely into market 0 — this pushes market 0
        // to ~100% of total assets, well above its 50% cap.
        // The deposit path does NOT enforce allocation caps (only rebalance
        // does), so this should succeed.
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        uint256 shares = optimizerZapper.swapAndDeposit(
            address(optimizer2), false, swapAction, 0, user1
        );
        vm.stopPrank();

        // Deposit succeeds — caps are rebalancing constraints, not deposit gates.
        assertGt(
            shares, 0, "Should receive optimizer shares despite exceeding cap"
        );
        assertEq(
            optimizer2.balanceOf(user1),
            shares,
            "Balance should match returned shares"
        );
        _assertOptimizerZapperHasNoResidue(address(optimizer2));
    }

    // ─── Additional Coverage ─────────────────────────────────────────

    function testSwapAndDeposit_fail_OptimizerPaused() public {
        // Pause the optimizer.
        optimizer.setMintPaused(true);

        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        // Optimizer's deposit reverts with MintPaused — propagates through zapper.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MintPaused.selector);
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 0, user1
        );
        assertEq(usdc.balanceOf(address(optimizerZapper)), 0);
        vm.stopPrank();
    }

    function _assertOptimizerZapperHasNoResidue(address optimizer_)
        internal
        view
    {
        assertEq(address(optimizerZapper).balance, 0, "zapper native residue");
        assertEq(
            usdc.balanceOf(address(optimizerZapper)), 0, "zapper USDC residue"
        );
        assertEq(
            dai.balanceOf(address(optimizerZapper)), 0, "zapper DAI residue"
        );
        assertEq(
            weth.balanceOf(address(optimizerZapper)), 0, "zapper WETH residue"
        );
        assertEq(
            LendingOptimizer(optimizer_).balanceOf(address(optimizerZapper)),
            0,
            "zapper optimizer share residue"
        );
    }
}
