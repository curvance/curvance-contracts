// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketManagerIsolated } from "tests/market/isolatedMarketManager/TestBaseMarketManagerIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import "forge-std/console2.sol";

// ## Scenario 2: Mixed Collateral Results
// - Setup: 4 users with different positions
// - User 1: 2.5 pBALRETH ($4,000), 2,500 USDC debt (very healthy)
// - User 2: 2.0 pBALRETH ($3,200), 2,500 USDC debt (healthy)
// - User 3: 1.8 pBALRETH ($2,880), 2,500 USDC debt (borderline)
// - User 4: 1.7 pBALRETH ($2,720), 2,500 USDC debt (risky)
// - Action: Price drop of pBALRETH by 10% (to $1,440)
// - Expected: Users 3 and 4 liquidated, Users 1 and 2 remain healthy

contract MixedCollateral is TestBaseMarketManagerIsolated {

    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");
    address borrower3 = makeAddr("borrower3");
    address borrower4 = makeAddr("borrower4");
    address borrower5 = makeAddr("borrower5");

    uint256 borrowAmount = 2500e6;
    address[] borrowers = [borrower1, borrower2, borrower3, borrower4];

    uint256 WAD_SQUARED = 1e36;

    uint256 liqBaseIncentive;
    uint256 liqCurve;
    uint256 baseCFactor;
    uint256 cFactorCurve;

    event BadDebtRecognized(address liquidator, uint256 amount);

    function setUp() public override {
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

        // use mock pricing for testing
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        chainlinkEthUsd.updateAnswer(1500e8);
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        _prepareUSDC(user1, _ONE);
        _prepareUSDC(address(this), _ONE);

        _prepareBALRETH(user1, _ONE + 42069);
        // _prepareUSDC(address(this), _ONE); // possibly not needed

        vm.prank(user1);
        usdc.approve(address(eUSDC), _ONE);
        balRETH.approve(address(pBALRETH), _ONE + 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));

        eUSDC.depositReserves(1000e6);
        // _prepareBALRETH(address(this), 10e18);
        // balRETH.approve(address(pBALRETH), 10e18);

        // Update position token parameters
        marketManager.updatePositionToken(
            8000,    // collRatio 80% 
            2500,    // collReqSoft 25%
            2200,    // collReqHard 22% (increased to be > liqIncMax + 1%)
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );


        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setCollateralCaps(tokens, caps);

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

        _createPositions();

        mockWethFeed.setMockAnswer(1380e8);
        mockRethFeed.setMockAnswer(1380e8);

        (,,,, uint256 liqBaseIncentive_, uint256 liqCurve_,,,,, uint256 baseCFactor_, uint256 cFactorCurve_) = 
            marketManager.tokenData(address(pBALRETH));

        liqBaseIncentive = liqBaseIncentive_;
        liqCurve = liqCurve_;
        baseCFactor = baseCFactor_;
        cFactorCurve = cFactorCurve_;
    }

    function _createPositions() internal {
        _prepareBALRETH(borrower1, _ONE);
        _prepareBALRETH(borrower2, _ONE);
        _prepareBALRETH(borrower3, _ONE);
        _prepareBALRETH(borrower4, _ONE);
        _prepareBALRETH(borrower5, _ONE);

        vm.startPrank(borrower1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.depositAsCollateral(_ONE, borrower1);
        eUSDC.borrow(borrowAmount);
        vm.stopPrank();

        vm.startPrank(borrower2);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.depositAsCollateral(_ONE, borrower2);
        eUSDC.borrow(borrowAmount);
        vm.stopPrank();

        vm.startPrank(borrower3);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.depositAsCollateral(_ONE, borrower3);
        eUSDC.borrow(borrowAmount);
        vm.stopPrank();

        vm.startPrank(borrower4);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.depositAsCollateral(_ONE, borrower4);
        eUSDC.borrow(borrowAmount);
        vm.stopPrank();

        vm.startPrank(borrower5);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.depositAsCollateral(_ONE, borrower5);
        eUSDC.borrow(borrowAmount);
        vm.stopPrank();
    }
}