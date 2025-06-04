// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestBaseETokenIsolated is TestBaseMarketIsolated {
    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

    function setUp() public virtual override {
        super.setUp();

        // use mock pricing for testing
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

        _prepareUSDC(user1, _ONE);
        _prepareUSDC(address(this), _ONE);
        _prepareBALRETH(address(this), 10e18);
        balRETH.approve(address(pBALRETH), 10e18);
        usdc.approve(address(eUSDC), _ONE);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));

        eUSDC.depositReserves(1000e6);


        vm.prank(user1);

        usdc.approve(address(eUSDC), _ONE);

        marketManager.updatePositionToken(
            7000,    // collRatio (70%)
            4000,    // collReqSoft (40%)
            3000,    // collReqHard (30%)
            200,     // liqIncBase (2% base incentive)
            400,     // liqIncHard (4% incentive at hard liq)
            200,     // liqIncMin (2% min dynamic penalty)
            400,     // liqIncMax (4% max dynamic penalty)
            1000,    // minEffectiveCFactor (10% min dynamic cFactor)
            3000,   // maxEffectiveCFactor (30% max dynamic cFactor)
            1000     // baseCFactor (10% base cFactor, 0.9 WAD curve)
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setCollateralCaps(tokens, caps);

        pBALRETH.mint(_ONE, address(this));
    }

    function _prepareLiquidation() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        // mint eUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(eUSDC), 200000e6);
        eUSDC.mint(200000e6);
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
