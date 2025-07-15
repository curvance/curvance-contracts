// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { ZapperBase } from "contracts/plugins/ZapperBase.sol";
import { SimpleCToken, IERC20 } from "contracts/market/token/SimpleCToken.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";

import "tests/market/TestBaseMarketIsolated.sol";

contract TestSimpleZapper is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address public owner;
    SimpleZapper public simpleZapper;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);

        simpleZapper = new SimpleZapper(
            ICentralRegistry(address(centralRegistry)),
            _WETH_ADDRESS
        );

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        // deploy eDAI
        {
            // support market
            _prepareDAI(owner, 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(borrowableCDAI));
        }

        // deploy simple pToken
        {
            _deploySimpleCUSDC();
            _prepareUSDC(owner, 100e6);
            usdc.approve(address(simpleCUSDC), 100e6);

        }

        marketManagerIsolated.listTokens(address(simpleCUSDC), address(borrowableCDAI));
        oracleManager.addCTokenSupport(address(simpleCUSDC));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(simpleCUSDC);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 1000;
        tokenConfig.collateralCap = 100 ether;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = address(borrowableCDAI);
        tokenConfig.debtCap = 100_000e18;
        marketManagerIsolated.updateTokenConfig(tokenConfig);

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

        SwapperLib.Swap memory swapData;
        swapData.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapData.inputAmount = ethAmount;
        swapData.target = _UNISWAP_V3_SWAP_ROUTER;
        swapData.outputToken = address(usdc);

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 3 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        vm.prank(user1);
        simpleZapper.swapAndDeposit{ value: ethAmount }(
            address(simpleCUSDC),
            false, // was false before contract refactor
            swapData,
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

        SwapperLib.Swap memory swapData;
        swapData.inputToken = _USDC_ADDRESS;
        swapData.inputAmount = 500e6;
        swapData.outputToken = _DAI_ADDRESS;
        swapData.target = _UNISWAP_V3_SWAP_ROUTER;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _DAI_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 500e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        _prepareUSDC(user1, 500e6);
        vm.startPrank(user1);
        usdc.approve(address(simpleZapper), 500e6);
        simpleZapper.swapAndRepay(
            address(borrowableCDAI),
            false,
            swapData,
            450e18,
            user1
        );
        vm.stopPrank();

        assertApproxEqAbs(dai.balanceOf(user1), 550 ether, 1 ether);
        assertApproxEqAbs(borrowableCDAI.debtBalance(user1), 50 ether, 1 ether);
    }

    function testRedeemAndSwapPToken() public {
        testSwapAndDeposit();

        vm.prank(user1);
        simpleCUSDC.setDelegateApproval(address(simpleZapper), true);

        uint256 shares = simpleCUSDC.balanceOf(user1);

        ZapperBase.RedemptionData memory redemptionData;
        redemptionData.cToken = address(simpleCUSDC);
        redemptionData.shares = shares;
        redemptionData.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapData;
        swapData.inputToken = _USDC_ADDRESS;
        swapData.inputAmount = shares;
        swapData.outputToken = _WETH_ADDRESS;
        swapData.target = _UNISWAP_V3_SWAP_ROUTER;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _WETH_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 2000e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        vm.prank(user1);
        simpleZapper.redeemAndSwap(redemptionData, swapData, user1);

        assertGt(weth.balanceOf(user1), 2.9 ether); // 3 ether - fees
    }

    function testRedeemAndSwapEToken() public {
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

        SwapperLib.Swap memory swapData;
        swapData.inputToken = _DAI_ADDRESS;
        swapData.inputAmount = 10 ether;
        swapData.outputToken = _USDC_ADDRESS;
        swapData.target = _UNISWAP_V3_SWAP_ROUTER;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 10 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        simpleZapper.redeemAndSwap(redemptionData, swapData, user1);

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

        SwapperLib.Swap memory swapData;
        swapData.inputToken = _DAI_ADDRESS;
        swapData.inputAmount = 100 ether;
        swapData.outputToken = _USDC_ADDRESS;
        swapData.target = _UNISWAP_V3_SWAP_ROUTER;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 100 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        vm.startPrank(user1);

        simpleZapper.redeemSwapAndDeposit(
            address(simpleCUSDC),
            redemptionData,
            swapData,
            0,
            false,
            user1
        );
        vm.stopPrank();

        assertGt(simpleCUSDC.balanceOf(user1), 99e6);
    }
}
