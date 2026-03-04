// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { OptimizerZapper } from "contracts/plugins/market/OptimizerZapper.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

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
            ICentralRegistry(address(centralRegistry)),
            _WETH_ADDRESS
        );

        // Register Uniswap V3 calldata checker.
        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        // Deploy LendingOptimizer with borrowableCUSDC as the sole market.
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

        // List borrowableCUSDC so market manager accepts deposits.
        marketManagerIsolated.listTokens(
            address(simpleCUSDC),
            address(borrowableCUSDC)
        );
        _setCTokenConfigBasic(
            address(borrowableCUSDC),
            100_000e18,
            100_000e18
        );
        _setCTokenConfigHighValues(address(simpleCUSDC), 100_000e18, 0);

        // Initialize the optimizer (mint dead shares).
        _prepareUSDC(address(this), 100e6);
        usdc.approve(address(optimizer), 100e6);
        optimizer.initializeDeposits(0);

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
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        vm.prank(user1);
        uint256 shares = optimizerZapper.swapAndDeposit{ value: ethAmount }(
            address(optimizer),
            address(borrowableCUSDC),
            false,
            swapAction,
            0,
            user1
        );

        assertEq(user1.balance, 0, "User should have spent all ETH");
        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(optimizer.balanceOf(user1), shares, "Balance should match returned shares");
        assertEq(usdc.balanceOf(address(optimizerZapper)), 0, "Zapper should hold no USDC");
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

        uint256 shares = optimizerZapper.swapAndDeposit(
            address(optimizer),
            address(borrowableCUSDC),
            false,
            swapAction,
            0,
            user1
        );
        vm.stopPrank();

        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(optimizer.balanceOf(user1), shares, "Balance should match returned shares");
        assertEq(usdc.balanceOf(address(optimizerZapper)), 0, "Zapper should hold no USDC");
        assertEq(usdc.balanceOf(user1), 0, "User should have deposited all USDC");
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

        uint256 shares = optimizerZapper.swapAndDeposit(
            address(optimizer),
            address(borrowableCUSDC),
            false,
            swapAction,
            0,
            user2
        );
        vm.stopPrank();

        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(optimizer.balanceOf(user2), shares, "Receiver should hold shares");
        assertEq(optimizer.balanceOf(user1), 0, "Sender should hold no shares");
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

        vm.expectRevert(OptimizerZapper.OptimizerZapper__ExecutionError.selector);
        optimizerZapper.swapAndDeposit(
            address(optimizer),
            address(borrowableCUSDC),
            false,
            swapAction,
            0,
            address(0)
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

        vm.expectRevert(OptimizerZapper.OptimizerZapper__AssetMismatch.selector);
        optimizerZapper.swapAndDeposit(
            address(optimizer),
            address(borrowableCUSDC),
            false,
            swapAction,
            0,
            user1
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
        vm.expectRevert(OptimizerZapper.OptimizerZapper__ExecutionError.selector);
        optimizerZapper.swapAndDeposit(
            address(optimizer),
            address(borrowableCUSDC),
            false,
            swapAction,
            type(uint256).max,
            user1
        );
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

        vm.expectRevert(OptimizerZapper.OptimizerZapper__ExecutionError.selector);
        optimizerZapper.swapAndDeposit{ value: 1 ether }(
            address(optimizer),
            address(borrowableCUSDC),
            false,
            swapAction,
            0,
            user1
        );
        vm.stopPrank();
    }

    // ─── Multi-Market / Allocation Cap ───────────────────────────────

    function testSwapAndDeposit_TwoMarkets_ExceedsCap() public {
        // Deploy a second borrowable USDC cToken.
        BorrowableCToken borrowableCUSDC2 = _deployBorrowableCToken(_USDC_ADDRESS);
        oracleManager.addCTokenSupport(address(borrowableCUSDC2));

        // Deploy a fresh optimizer with two markets at 50% cap each.
        address[] memory cTokens = new address[](2);
        cTokens[0] = address(borrowableCUSDC);
        cTokens[1] = address(borrowableCUSDC2);
        uint256[] memory caps = new uint256[](2);
        caps[0] = 5000; // 50%
        caps[1] = 5000; // 50%

        LendingOptimizer optimizer2 = new LendingOptimizer(
            usdc,
            ICentralRegistry(address(centralRegistry)),
            cTokens,
            caps,
            0
        );

        // Initialize the optimizer.
        _prepareUSDC(address(this), 1e6);
        usdc.approve(address(optimizer2), 1e6);
        optimizer2.initializeDeposits(0);

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
            address(optimizer2),
            address(borrowableCUSDC), // target market 0
            false,
            swapAction,
            0,
            user1
        );
        vm.stopPrank();

        // Deposit succeeds — caps are rebalancing constraints, not deposit gates.
        assertGt(shares, 0, "Should receive optimizer shares despite exceeding cap");
        assertEq(optimizer2.balanceOf(user1), shares, "Balance should match returned shares");
    }

    // ─── Additional Coverage ─────────────────────────────────────────

    function testSwapAndDeposit_DustRefund() public {
        // Seed some USDC dust into the zapper from a prior interaction.
        uint256 dust = 50e6;
        _prepareUSDC(address(optimizerZapper), dust);

        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        uint256 usdcBefore = usdc.balanceOf(user1);
        optimizerZapper.swapAndDeposit(
            address(optimizer),
            address(borrowableCUSDC),
            false,
            swapAction,
            0,
            user1
        );
        vm.stopPrank();

        // Dust from prior interaction is swept to caller.
        assertEq(usdc.balanceOf(address(optimizerZapper)), 0, "Zapper should be empty");
        assertEq(usdc.balanceOf(user1), dust, "Caller should receive dust");
    }

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
            address(optimizer),
            address(borrowableCUSDC),
            false,
            swapAction,
            0,
            user1
        );
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_InvalidTargetMarket() public {
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        // Pass an address that isn't in the optimizer's approved list.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketNotApproved.selector);
        optimizerZapper.swapAndDeposit(
            address(optimizer),
            address(0xdead),
            false,
            swapAction,
            0,
            user1
        );
        vm.stopPrank();
    }
}
