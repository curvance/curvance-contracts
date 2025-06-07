// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { ZapperBase } from "contracts/plugins/ZapperBase.sol";
import { SimplePToken, IERC20 } from "contracts/market/token/SimplePToken.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";

import "tests/market/TestBaseMarketIsolated.sol";

contract User {}

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
            dai.approve(address(eDAI), 200000e18);
            marketManagerIsolated.listToken(address(eDAI));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eDAI));
        }

        // deploy simple pToken
        {
            _deployPUSDC();
            _prepareUSDC(owner, 100e6);
            usdc.approve(address(pUSDC), 100e6);
            marketManagerIsolated.listToken(address(pUSDC));
            oracleManager.addMTokenSupport(address(pUSDC));
            marketManagerIsolated.updatePositionToken(
                address(pUSDC),
                7000,
                4000, // liquidate at 71%
                3000,
                200, // 2% liq incentive
                400,
                1000
            );

            address[] memory mTokens = new address[](1);
            mTokens[0] = address(pUSDC);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100 ether;
            marketManagerIsolated.setCollateralCaps(mTokens, caps);
        }

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 1000 ether);
        _prepareUSDC(liquidityProvider, 100e6);
        vm.startPrank(liquidityProvider);
        // mint eDAI
        dai.approve(address(eDAI), 1000 ether);
        eDAI.mint(1000 ether);
        // mint pUSDC
        usdc.approve(address(pUSDC), 100e6);
        pUSDC.mint(100e6, liquidityProvider);
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
            address(pUSDC),
            true,
            false,
            swapData,
            0,
            false,
            user1
        );

        assertEq(user1.balance, 0);
        assertGt(pUSDC.balanceOf(user1), 0);
    }

    function testSwapAndRepay() external {
        testSwapAndDeposit();
        vm.startPrank(user1);
        pUSDC.postCollateral(2e9);

        // try borrow()
        eDAI.borrow(500 ether);
        vm.stopPrank();

        assertEq(dai.balanceOf(user1), 500 ether);
        assertApproxEqAbs(eDAI.debtBalanceCached(user1), 500 ether, 1 ether);

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
            address(eDAI),
            false,
            swapData,
            450e18,
            user1
        );
        vm.stopPrank();

        assertApproxEqAbs(dai.balanceOf(user1), 550 ether, 1 ether);
        assertApproxEqAbs(eDAI.debtBalanceCached(user1), 50 ether, 1 ether);
    }

    function testRedeemAndSwapPToken() public {
        testSwapAndDeposit();

        vm.prank(user1);
        pUSDC.setDelegateApproval(address(simpleZapper), true);

        uint256 shares = pUSDC.balanceOf(user1);

        ZapperBase.RedemptionData memory redemptionData;
        redemptionData.mToken = address(pUSDC);
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

        // mint eDAI
        _prepareDAI(user1, 10 ether);
        dai.approve(address(eDAI), 10 ether);
        eDAI.mint(10 ether);

        eDAI.setDelegateApproval(address(simpleZapper), true);

        ZapperBase.RedemptionData memory redemptionData;
        redemptionData.mToken = address(eDAI);
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
        // redeem eDAI and deposit to pUSDC

        _prepareDAI(user1, 100 ether);
        dai.approve(address(eDAI), 100 ether);
        eDAI.mint(100 ether);

        eDAI.setDelegateApproval(address(simpleZapper), true);

        ZapperBase.RedemptionData memory redemptionData;
        redemptionData.mToken = address(eDAI);
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

        simpleZapper.redeemSwapAndDeposit(
            address(pUSDC),
            redemptionData,
            swapData,
            0,
            false,
            user1
        );

        assertGt(pUSDC.balanceOf(user1), 99e6);
    }
}
