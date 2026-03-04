// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { ProtocolReader } from "contracts/views/ProtocolReader.sol";
    
contract HighLTVLiquidations is TestBaseLiquidations {

    SimplePositionManager simplePositionManager;

    function setUp() public override {
        super.setUp();

        simplePositionManager = new SimplePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS
        );

        marketManagerIsolated.addPositionManager(address(simplePositionManager));

        _prepareUSDC(address(this), 77777);
        _prepareWETH(address(this), 77777);

        usdc.approve(address(borrowableCUSDC), 77777);
        weth.approve(address(borrowableCWETH), 77777);

        marketManagerIsolated.listTokens(address(borrowableCWETH), address(borrowableCUSDC));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(borrowableCUSDC);
        tokenConfig.collRatio = 9696;
        tokenConfig.collReqSoft = 220;
        tokenConfig.collReqHard = 200;
        tokenConfig.liqIncBase = 60;
        tokenConfig.liqIncHard = 90;
        tokenConfig.liqIncMin = 30;
        tokenConfig.liqIncMax = 90;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 1_000_000e6;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = address(borrowableCWETH);
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 1_000_000e18;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        // Mint borrowable cUSDC and cWETH for liquidity provider
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 2_000_000e6);
        _prepareWETH(liquidityProvider, 10e18);
       
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 2_000_000e6);
        borrowableCUSDC.deposit(2_000_000e6, liquidityProvider);

        weth.approve(address(borrowableCWETH), 10e18);
        borrowableCWETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

    }

    function test_liquidate_highLTV_noLeverage() public {

        vm.startPrank(user1);
        _prepareWETH(user1, 10e18);
        weth.approve(address(borrowableCWETH), 10e18);
        borrowableCWETH.depositAsCollateral(10e18, user1);

        ProtocolReader.HypotheticalResult memory hypotheticalResult = protocolReader.hypotheticalLiquidityOf(
            IMarketManager(address(marketManagerIsolated)),
            user1,
            address(0),
            0,
            0,
            0
        );

        (uint256 usdcPrice, ) = protocolReader.getPrice(_USDC_ADDRESS, true, false);

        uint256 maxDebtScaled = (hypotheticalResult.maxDebt * (10 ** usdc.decimals())) / usdcPrice;

        borrowableCUSDC.borrow(maxDebtScaled, user1);
        vm.stopPrank();

        skip(20 minutes);

        // 1% price drop
        mockWethFeed.setMockAnswer((4476e8 * 99 / 100));
        _refreshMockFeeds();

        _prepareUSDC(user2, 100_000e6);

        // Accrue interest so we can calculate the exact debt
        uint256 user1DebtBefore = borrowableCUSDC.debtBalanceUpdated(user1);
        uint256 user1CollBefore = borrowableCWETH.collateralPosted(user1);
        uint256 user2UsdcBefore = usdc.balanceOf(user2);
        uint256 user2CollBefore = borrowableCWETH.balanceOf(user2);

        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 100_000e6);

        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        borrowableCUSDC.liquidate(accounts, address(borrowableCWETH));

        // seized shares == borrower share decrease
        uint256 seized = borrowableCWETH.balanceOf(user2) - user2CollBefore;
        assertEq(seized, user1CollBefore - borrowableCWETH.collateralPosted(user1), "seized shares == borrower share decrease");

        // USDC paid == borrower debt reduction
        uint256 paid = user2UsdcBefore - usdc.balanceOf(user2);
        assertEq(paid, user1DebtBefore - borrowableCUSDC.debtBalance(user1), "USDC paid == borrower debt reduction");

        // Incentive value check (no bad debt path)
        (uint256 incBase, uint256 incCurve, , , , , , ) =
            marketManagerIsolated.liquidationConfig(address(borrowableCWETH));
        uint256 incHard = incBase + incCurve;

        (uint256 collateralPrice, ) = protocolReader.getPrice(address(borrowableCWETH), true, true);
        (uint256 debtPrice, ) = protocolReader.getPrice(_USDC_ADDRESS, true, false);
        uint256 seizedUsd = (seized * collateralPrice) / (10 ** borrowableCWETH.decimals());
        uint256 paidUsd = (paid * debtPrice + (10 ** borrowableCUSDC.decimals()) - 1) / (10 ** borrowableCUSDC.decimals());
        
        uint256 calculatedInc = (seizedUsd * 10000 + paidUsd - 1) / paidUsd;
        assertGe(calculatedInc, incBase, "incentive below base");
        assertLe(calculatedInc, incHard, "incentive above hard");

    }

    function test_liquidate_highLTV_maxLeverage() public {

        vm.startPrank(user1);

        // Using small collateral to reduce the amount of slippage when leveraging
        _prepareWETH(user1, 0.01e18);
        weth.approve(address(borrowableCWETH), 0.01e18);
        borrowableCWETH.depositAsCollateral(0.01e18, user1);
        vm.stopPrank();

        (
            uint256 currentLeverage,
            uint256 adjustedMaxLeverage,
            uint256 maxLeverage,
            uint256 maxDebtBorrowable,
            bool loanSizeError,
            bool oracleError
        ) = protocolReader.hypotheticalLeverageOf(
            user1,
            address(borrowableCWETH),
            address(borrowableCUSDC),
            0,
            0
        );

        maxDebtBorrowable = (maxDebtBorrowable * 9830) / 10000;

        IPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        leverageAction.borrowAssets = maxDebtBorrowable;
        leverageAction.cToken = ICToken(address(borrowableCWETH));
        leverageAction.expectedShares = 0;
        address[] memory path = new address[](2);
        path[0] = _USDC_ADDRESS;
        path[1] = _WETH_ADDRESS;
        leverageAction.swapAction = SwapperLib.Swap({
            inputToken: _USDC_ADDRESS,
            inputAmount: maxDebtBorrowable,
            outputToken: _WETH_ADDRESS,
            target: address(_UNISWAP_V2_ROUTER),
            call: abi.encodeWithSignature(
                "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
                maxDebtBorrowable,
                0,
                path,
                address(simplePositionManager),
                block.timestamp
            ),
            slippage: 0.05e18
        });

        vm.startPrank(user1);
        simplePositionManager.leverage(leverageAction, 0.05e18); // 5% slippage
        vm.stopPrank();

        skip(20 minutes);

        // 1% price drop
        mockWethFeed.setMockAnswer((4476e8 * 99 / 100));
        _refreshMockFeeds();

        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        vm.startPrank(user2);
        _prepareUSDC(user2, 100_000e6);

        uint256 user1DebtBefore = borrowableCUSDC.debtBalanceUpdated(user1);
        uint256 user1CollBefore = borrowableCWETH.collateralPosted(user1);
        uint256 user2UsdcBefore = usdc.balanceOf(user2);
        uint256 user2CollBefore = borrowableCWETH.balanceOf(user2);

        usdc.approve(address(borrowableCUSDC), 100_000e6);
        borrowableCUSDC.liquidate(accounts, address(borrowableCWETH));
        vm.stopPrank();

        uint256 seized = borrowableCWETH.balanceOf(user2) - user2CollBefore;
        assertEq(seized, user1CollBefore - borrowableCWETH.collateralPosted(user1), "seized shares == borrower share decrease");
        uint256 paid = user2UsdcBefore - usdc.balanceOf(user2);
        assertEq(paid, user1DebtBefore - borrowableCUSDC.debtBalance(user1), "USDC paid == borrower debt reduction");

        // Incentive value check (no bad debt path)
        (uint256 incBase, uint256 incCurve, , , , , , ) =
            marketManagerIsolated.liquidationConfig(address(borrowableCWETH));
        uint256 incHard = incBase + incCurve;

        (uint256 collateralPrice, ) = protocolReader.getPrice(address(borrowableCWETH), true, true);
        (uint256 debtPrice, ) = protocolReader.getPrice(_USDC_ADDRESS, true, false);

        uint256 seizedUsd = (seized * collateralPrice) / (10 ** borrowableCWETH.decimals());
        uint256 paidUsd = (paid * debtPrice + (10 ** borrowableCUSDC.decimals()) - 1) / (10 ** borrowableCUSDC.decimals());
        uint256 calculatedInc = (seizedUsd * 10000 + paidUsd - 1) / paidUsd;

        assertGe(calculatedInc, incBase, "incentive below base");
        assertLe(calculatedInc, incHard, "incentive above hard");
    }   
}