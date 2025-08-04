// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { console2 } from "forge-std/console2.sol";

// Borrowing 700 USDC = $700
// 1 WETH as collateral = $1000

// $714.29 loan soft liquidation price

contract TestLiquidationCausedByInterest is TestBaseLiquidations {

    IBorrowableCToken borrowableCWETH;

    address liquidityProvider = makeAddr("lp");

    function setUp() public override {
        super.setUp();

        borrowableCWETH = IBorrowableCToken(address(_deployBorrowableCToken(_WETH_ADDRESS)));

        oracleManager.addCTokenSupport(address(borrowableCWETH));

        _prepareWETH(address(this), 77777);
        _prepareUSDC(address(this), 77777);

        weth.approve(address(borrowableCWETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(borrowableCWETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(borrowableCWETH), 100e18, 100e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e6, 100_000e6);

        _prepareUSDC(liquidityProvider, 100_000e6);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 100_000e6);
        borrowableCUSDC.deposit(1000e6, liquidityProvider);
        vm.stopPrank();

        mockWethFeed.setMockAnswer(1000e8);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockUsdcFeed.setMockAnswer(1e8);
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
    }

    function test_success_LiquidationCausedByInterest() public {
        _prepareWETH(user1, 1e18);
        vm.startPrank(user1);
        weth.approve(address(borrowableCWETH), 1e18);
        borrowableCWETH.depositAsCollateral(1e18, user1);
        borrowableCUSDC.borrow(700e6, user1);
        vm.stopPrank();

        uint256 lFactor;

        uint256 timeBefore = block.timestamp;

        do {
            skip(90 days);
            mockWethFeed.setMockUpdatedAt(block.timestamp);
            mockUsdcFeed.setMockUpdatedAt(block.timestamp);
            borrowableCUSDC.accrueIfNeeded();
            (lFactor,,) = marketManagerIsolated.liquidationStatusOf(user1, address(borrowableCWETH), address(borrowableCUSDC));
            console2.log("marketOutstandingDebt", borrowableCUSDC.marketOutstandingDebt());
            console2.log("lFactor", lFactor);
        } while (lFactor == 0);
        console2.log("lFactor", lFactor);
        console2.log("time", ((block.timestamp - timeBefore) / 1 days));

    }






}