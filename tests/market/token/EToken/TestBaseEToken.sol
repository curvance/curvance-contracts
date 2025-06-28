// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TestBaseEToken is TestBaseMarketIsolated {
    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

    function setUp() public virtual override {
        super.setUp();

        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        mockRethFeed = new MockDataFeed(_CHAINLINK_RETH_ETH);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            false
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            false
        );

        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        chainlinkEthUsd.updateAnswer(1500e8);
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        _prepareUSDC(address(this), _ONE + 77777);
        _prepareBALRETH(address(this), 10e18 + 77777);
        
        usdc.approve(address(eUSDC), _ONE + 77777);
        balRETH.approve(address(pBALRETH), 10e18 + 77777);

        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));

        MarketManagerIsolated.TokenConfig memory configToken0;
        configToken0.cToken = address(pBALRETH);
        configToken0.collRatio = 7000;
        configToken0.collReqSoft = 4000;
        configToken0.collReqHard = 3000;
        configToken0.liqIncBase = 1000;
        configToken0.liqIncHard = 1500;
        configToken0.liqIncMin = 500;
        configToken0.liqIncMax = 2000;
        configToken0.minEffectiveCloseFactor = 2000;
        configToken0.maxEffectiveCloseFactor = 3000;
        configToken0.baseCFactor = 1000;
        configToken0.collateralCap = 100_000e18;
        configToken0.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(configToken0);

        MarketManagerIsolated.TokenConfig memory configToken1;
        configToken1.cToken = address(eUSDC);
        configToken1.debtCap = 100_000e6;
        marketManagerIsolated.updateTokenConfig(configToken1);
        

        pBALRETH.mint(_ONE, address(this));
    }

    function _prepareLiquidation() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        // mint eUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(eUSDC), 200000e6);
        eUSDC.deposit(200000e6, liquidityProvider);
        // mint cBALETH
        balRETH.approve(address(pBALRETH), 10e18);
        pBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();

        _prepareBALRETH(user1, _ONE);

        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        pBALRETH.postCollateral(_ONE - 1);

        eUSDC.borrow(1000e6);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockUsdcFeed.setMockAnswer(2e8);

        _prepareUSDC(user2, 250e6);
    }
}
