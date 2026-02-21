// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { BaseZapper } from "contracts/plugins/BaseZapper.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { SimpleCToken, IERC20 } from "contracts/market/token/SimpleCToken.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

contract TestSimpleZapper is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    SimpleZapper public simpleZapper;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        oracleManager.addCTokenSupport(address(simpleCUSDC));

        simpleZapper = new SimpleZapper(
            ICentralRegistry(address(centralRegistry)),
            _WETH_ADDRESS
        );

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        _prepareDAI(address(this), 200000e18);
        dai.approve(address(borrowableCDAI), 200000e18);

        _prepareUSDC(address(this), 100e6);
        usdc.approve(address(simpleCUSDC), 100e6);

        marketManagerIsolated.listTokens(address(simpleCUSDC), address(borrowableCDAI));
        
        _setCTokenConfigHighValues(address(simpleCUSDC), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 1000 ether);
        _prepareUSDC(liquidityProvider, 100e6);

        vm.startPrank(liquidityProvider);

        // Mint borrowable cDAI.
        dai.approve(address(borrowableCDAI), 1000 ether);
        borrowableCDAI.deposit(1000 ether, liquidityProvider);
        // mint simpleCUSDC
        usdc.approve(address(simpleCUSDC), 100e6);
        simpleCUSDC.mint(100e6, liquidityProvider);

        vm.stopPrank();
    }

    function testSwapAndDeposit() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.inputAmount = ethAmount;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = address(usdc);

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 3 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        vm.prank(user1);
        simpleZapper.swapAndDeposit{ value: ethAmount }(
            address(simpleCUSDC),
            false, // was false before contract refactor
            swapAction,
            0,
            false,
            user1
        );

        assertEq(user1.balance, 0);
        assertGt(simpleCUSDC.balanceOf(user1), 0);
    }

    function testSwapAndRepay() external {
        testSwapAndDeposit();
        vm.startPrank(user1);
        simpleCUSDC.postCollateral(2e9);

        // try borrow()
        borrowableCDAI.borrow(500 ether, user1);
        vm.stopPrank();

        assertEq(dai.balanceOf(user1), 500 ether);
        assertApproxEqAbs(borrowableCDAI.debtBalance(user1), 500 ether, 1 ether);

        // skip min hold period
        skip(20 minutes);

        uint256 debt = borrowableCDAI.debtBalanceUpdated(user1);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 505e6; // Buffer so we dont end up with lower than min loan.
        swapAction.outputToken = _DAI_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _DAI_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 505e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        _prepareUSDC(user1, 505e6);
        vm.startPrank(user1);
        usdc.approve(address(simpleZapper), 505e6);
        simpleZapper.swapAndRepay(
            address(borrowableCDAI),
            false,
            swapAction,
            debt,// swapAndRepay will repay up to totalDebt and refund dust
            user1
        );
        vm.stopPrank();

        assertEq(borrowableCDAI.debtBalance(user1), 0);
        assertGt(dai.balanceOf(user1), 500 ether, "user should receive swap dust");
    }

    function testSwapAndRepay_fail_ZeroRepayAssets() external {
        SwapperLib.Swap memory swapAction;

        vm.prank(user1);
        vm.expectRevert(BaseZapper.BaseZapper__InvalidRepaymentAmount.selector);
        simpleZapper.swapAndRepay(
            address(borrowableCDAI),
            false,
            swapAction,
            0,
            user1
        );
    }

    function testSwapAndRepayDifferentRepayer() external {
        testSwapAndDeposit();
        vm.startPrank(user1);
        simpleCUSDC.postCollateral(2e9);

        // try borrow()
        borrowableCDAI.borrow(500 ether, user1);
        vm.stopPrank();

        assertEq(dai.balanceOf(user1), 500 ether);

        // skip min hold period
        skip(20 minutes);

        uint256 user2DaiBalanceBefore = dai.balanceOf(user2);
        uint256 debt = borrowableCDAI.debtBalanceUpdated(user1);

        // swap 501 as a buffer for interest and slippage.
        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 505e6; // buffer for interest + swap fee
        swapAction.outputToken = _DAI_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _DAI_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 505e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        // user2 pays the debt, and should receive the excess dai from the swap.
        _prepareUSDC(user2, 505e6);
        vm.startPrank(user2);
        usdc.approve(address(simpleZapper), 505e6);
        simpleZapper.swapAndRepay(
            address(borrowableCDAI),
            false,
            swapAction,
            debt, // must be non-zero
            user1
        );
        vm.stopPrank();

        uint256 user2DaiBalanceAfter = dai.balanceOf(user2);
        assertGt(user2DaiBalanceAfter, user2DaiBalanceBefore, "Excess dai should be sent to user2");

        assertEq(borrowableCDAI.debtBalance(user1), 0, "Debt should be fully repaid");
    }

    function testRedeemAndSwapCToken() public {
        testSwapAndDeposit();

        vm.prank(user1);
        simpleCUSDC.setDelegateApproval(address(simpleZapper), true);

        uint256 shares = simpleCUSDC.balanceOf(user1);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(simpleCUSDC);
        redeemAction.shares = shares;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = shares;
        swapAction.outputToken = _WETH_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _WETH_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = shares;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        vm.prank(user1);
        simpleZapper.redeemAndSwap(redeemAction, swapAction, user1);

        assertGt(weth.balanceOf(user1), 2.99 ether, "weth balance of user1 mismatch"); // 3 ether - fees
    }

    function testRedeemAndSwapBorrowableCToken() public {
        vm.startPrank(user1);

        // Mint borrowable cDAI.
        _prepareDAI(user1, 10 ether);
        dai.approve(address(borrowableCDAI), 10 ether);
        borrowableCDAI.deposit(10 ether, user1);

        borrowableCDAI.setDelegateApproval(address(simpleZapper), true);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(borrowableCDAI);
        redeemAction.shares = 10 ether;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = 10 ether;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 10 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        simpleZapper.redeemAndSwap(redeemAction, swapAction, user1);

        assertGt(usdc.balanceOf(user1), 9.99e6); // 10e6 - fees

        vm.stopPrank();
    }

    function testRedeemSwapAndDeposit() public {
        // redeem eDAI and deposit to simpleCUSDC

        _prepareDAI(user1, 100 ether);
        
        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 100 ether);
        borrowableCDAI.deposit(100 ether, user1);
        borrowableCDAI.setDelegateApproval(address(simpleZapper), true);
        vm.stopPrank();  

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(borrowableCDAI);
        redeemAction.shares = 100 ether;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = 100 ether;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 100 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        vm.startPrank(user1);

        simpleZapper.redeemSwapAndDeposit(
            address(simpleCUSDC),
            redeemAction,
            swapAction,
            0,
            false,
            user1
        );
        vm.stopPrank();

        assertGt(simpleCUSDC.balanceOf(user1), 99e6);
    }

    function test_Multicall_fail_native_doubleZap() public {

        uint256 ethAmount = 1 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.inputAmount = ethAmount;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = 0;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = ethAmount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        Multicall.MulticallAction[] memory calls = new Multicall.MulticallAction[](2);

        bytes memory data = abi.encodeWithSelector(
            simpleZapper.swapAndDeposit.selector,
            address(simpleCUSDC),
            false, // depositAsWrappedNative
            swapAction,
            0,
            false,
            user1
        );

        calls[0].target = address(simpleZapper);
        calls[0].isPriceUpdate = false;
        calls[0].data = data;

        calls[1].target = address(simpleZapper);
        calls[1].isPriceUpdate = false;
        calls[1].data = data;

        // if (inputAmount != msg.value) {
        //     revert BaseZapper__ExecutionError();
        // }
        vm.prank(user1);
        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        simpleZapper.multicall(calls);
    }

    function test_Multicall_success_nonNative() public {

        uint256 total = 10e6;
        uint256 half = total / 2;
        _prepareUSDC(user1, total);
        vm.startPrank(user1);
        usdc.approve(address(simpleZapper), total);

        SwapperLib.Swap memory swap1;
        swap1.inputToken = _USDC_ADDRESS;
        swap1.inputAmount = half;
        swap1.outputToken = _USDC_ADDRESS;

        SwapperLib.Swap memory swap2 = swap1;

        Multicall.MulticallAction[] memory calls = new Multicall.MulticallAction[](2);

        calls[0].target = address(simpleZapper);
        calls[0].isPriceUpdate = false;
        calls[0].data = abi.encodeWithSelector(
            simpleZapper.swapAndDeposit.selector,
            address(simpleCUSDC),
            false,
            swap1,
            0,
            false,
            user1
        );

        calls[1].target = address(simpleZapper);
        calls[1].isPriceUpdate = false;
        calls[1].data = abi.encodeWithSelector(
            simpleZapper.swapAndDeposit.selector,
            address(simpleCUSDC),
            false,
            swap2,
            0,
            false,
            user1
        );

        uint256 balanceBefore = simpleCUSDC.balanceOf(user1);
        simpleZapper.multicall(calls);
        vm.stopPrank();

        uint256 balanceAfter = simpleCUSDC.balanceOf(user1);

        assertGt(balanceAfter - balanceBefore, 0);
    }

    function test_swapAndDeposit_fail_whenMsgValueNonZeroWithNonNativeSwap() public {

        uint256 total = 10e6;
        deal(user1, 10 ether);
        _prepareUSDC(user1, total);
        vm.startPrank(user1);
        usdc.approve(address(simpleZapper), total);

        SwapperLib.Swap memory swap1;
        swap1.inputToken = _USDC_ADDRESS;
        swap1.inputAmount = total;
        swap1.outputToken = _USDC_ADDRESS;

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);

        simpleZapper.swapAndDeposit{value: 10 ether}(
            address(simpleCUSDC),
            false,
            swap1,
            0,
            false,
            user1
        );

        vm.stopPrank();
    }

    function test_swapAndRepay_fail_whenMsgValueNonZeroWithNonNativeSwap() public {

        uint256 total = 100e6;
        _prepareUSDC(user1, total);
        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), total);

        simpleCUSDC.depositAsCollateral(100e6, user1);
        borrowableCDAI.borrow(20e18, user1);

        skip(20 minutes);

        borrowableCDAI.setDelegateApproval(address(simpleZapper), true);

        _prepareUSDC(user1, 20e6);

        usdc.approve(address(simpleZapper), 20e6);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = address(usdc);
        swapAction.inputAmount = 20e6;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = address(dai);

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _DAI_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 20e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        vm.deal(user1, 100 ether);

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);

        simpleZapper.swapAndRepay{value: 100 ether}(
            address(borrowableCDAI),
            false,
            swapAction,
            19e18,
            user1
        );

        vm.stopPrank();


    }
}
