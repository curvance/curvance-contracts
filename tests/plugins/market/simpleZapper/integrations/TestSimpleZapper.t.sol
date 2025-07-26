// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { ZapperBase } from "contracts/plugins/ZapperBase.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { SimpleCToken, IERC20 } from "contracts/market/token/SimpleCToken.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";

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

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 500e6;
        swapAction.outputToken = _DAI_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _DAI_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 500e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        _prepareUSDC(user1, 500e6);
        vm.startPrank(user1);
        usdc.approve(address(simpleZapper), 500e6);
        simpleZapper.swapAndRepay(
            address(borrowableCDAI),
            false,
            swapAction,
            450e18,
            user1
        );
        vm.stopPrank();

        assertApproxEqAbs(dai.balanceOf(user1), 550 ether, 1 ether);
        assertApproxEqAbs(borrowableCDAI.debtBalance(user1), 50 ether, 1 ether);
    }

    function testRedeemAndSwapCToken() public {
        testSwapAndDeposit();

        vm.prank(user1);
        simpleCUSDC.setDelegateApproval(address(simpleZapper), true);

        uint256 shares = simpleCUSDC.balanceOf(user1);

        ZapperBase.RedemptionData memory redemptionData;
        redemptionData.cToken = address(simpleCUSDC);
        redemptionData.shares = shares;
        redemptionData.forceRedeemCollateral = false;

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
        params.amountIn = 2000e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        vm.prank(user1);
        simpleZapper.redeemAndSwap(redemptionData, swapAction, user1);

        assertGt(weth.balanceOf(user1), 2.9 ether); // 3 ether - fees
    }

    function testRedeemAndSwapBorrowableCToken() public {
        vm.startPrank(user1);

        // Mint borrowable cDAI.
        _prepareDAI(user1, 10 ether);
        dai.approve(address(borrowableCDAI), 10 ether);
        borrowableCDAI.deposit(10 ether, user1);

        borrowableCDAI.setDelegateApproval(address(simpleZapper), true);

        ZapperBase.RedemptionData memory redemptionData;
        redemptionData.cToken = address(borrowableCDAI);
        redemptionData.shares = 10 ether;
        redemptionData.forceRedeemCollateral = false;

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

        simpleZapper.redeemAndSwap(redemptionData, swapAction, user1);

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

        ZapperBase.RedemptionData memory redemptionData;
        redemptionData.cToken = address(borrowableCDAI);
        redemptionData.shares = 100 ether;
        redemptionData.forceRedeemCollateral = false;

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
            redemptionData,
            swapAction,
            0,
            false,
            user1
        );
        vm.stopPrank();

        assertGt(simpleCUSDC.balanceOf(user1), 99e6);
    }
}
