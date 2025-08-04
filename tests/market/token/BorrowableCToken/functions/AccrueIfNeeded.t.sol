// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { console2 } from "forge-std/console2.sol";

contract TestAccrueIfNeeded is TestBaseMarketIsolated {

    address daoAddress;
    address liquidityProvider;

    function setUp() public virtual override {
        super.setUp();

        _prepareUSDC(address(this), 77777);
        _prepareBALRETH(address(this), 77777);
        
        usdc.approve(address(borrowableCUSDC), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        liquidityProvider = makeAddr("liqProvider");
        _prepareUSDC(liquidityProvider, 100_000e6);

        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, liquidityProvider);
        vm.stopPrank();

        mockUsdcFeed.setMockAnswer(1e9);
        mockRethFeed.setMockAnswer(2000e9);
        mockWethFeed.setMockAnswer(2000e9);

        daoAddress = centralRegistry.daoAddress();
    }
    
    function test_vestingPeriod_skipTenMinutesPlus1Second() public {
       uint256 borrowAmount = 500e6;
        borrowableCUSDC.accrueIfNeeded();
        
        _prepareBALRETH(user1, 250e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 250e18);
        strategyCBALRETH.depositAsCollateral(250e18, user1);
        borrowableCUSDC.borrow(borrowAmount, user1);
        vm.stopPrank();

        uint256 totalAssetsBefore = borrowableCUSDC.totalAssets();
        uint256 totalSharesBefore = borrowableCUSDC.totalSupply();
        uint256 daoSharesBefore = borrowableCUSDC.balanceOf(daoAddress);
        (uint256 vestingRateBefore,uint256 outstandingDebtBefore, uint256 vestingEndBefore, uint256 lastVestBefore) = borrowableCUSDC.getVestingData();

        console2.log("totalAssets:", totalAssetsBefore);
        console2.log("totalShares:", totalSharesBefore);
        console2.log("outstandingDebt:", outstandingDebtBefore);
        console2.log("daoShares:", daoSharesBefore);

        for(uint i; i < 10; i++) {
            skip(10 minutes + 1 seconds);
            borrowableCUSDC.accrueIfNeeded();
        }

        uint256 totalAssetsAfter = borrowableCUSDC.totalAssets();
        uint256 totalSharesAfter = borrowableCUSDC.totalSupply();
        uint256 daoSharesAfter = borrowableCUSDC.balanceOf(daoAddress);
          (uint256 vestingRateAfter,uint256 outstandingDebtAfter, uint256 vestingEndAfter, uint256 lastVestAfter) = borrowableCUSDC.getVestingData();

        console2.log("totalAssets:", totalAssetsAfter);
        console2.log("totalShares:", totalSharesAfter);
        console2.log("outstandingDebt:", outstandingDebtAfter);
        console2.log("daoShares:", daoSharesAfter);

        uint256 assetIncrease = totalAssetsAfter - totalAssetsBefore;
        uint256 sharesIncrease = totalSharesAfter - totalSharesBefore;
        uint256 debtIncrease = outstandingDebtAfter - outstandingDebtBefore;
        uint256 daoSharesIncrease = daoSharesAfter - daoSharesBefore;
        uint256 daoAssetsIncrease  = borrowableCUSDC.convertToAssets(daoSharesIncrease);

        console2.log("assetIncrease:", assetIncrease);
        console2.log("debtIncrease:", debtIncrease);
        console2.log("daoSharesIncrease:", daoSharesIncrease);
        console2.log("daoAssetsIncrease:", daoAssetsIncrease);
        assertEq(assetIncrease, debtIncrease, "Asset increase should equal debt increase");
    }
}