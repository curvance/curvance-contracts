// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "tests/market/marketManager/TestBaseMarketManager.sol";
import { LiquidityManager } from "contracts/market/LiquidityManager.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IMToken, AccountSnapshot } from "contracts/interfaces/IMToken.sol";

contract CanBorrowWithNotifyIsolatedMarketManager is TestBaseMarketManager {

    function setUp() public override {
        super.setUp();

        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETHIsolated), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDCIsolated), 42069);

        marketManagerIsolated.listTokens(address(pBALRETHIsolated), address(eUSDCIsolated));
    }

    function test_canBorrowWithNotify_fail_whenCallerIsNotMToken() public {
        vm.expectRevert(0x37cf6ad5);
        marketManagerIsolated.canBorrowWithNotify(address(eUSDCIsolated), user1, 100e6);
    }

    function test_canBorrowWithNotify_fail_whenMTokenIsNotListed() public {

        vm.prank(address(eDAI));

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canBorrowWithNotify(address(eDAI), user1, 100e6);
    }

    function test_canBorrowWithNotify_fail_whenBorrowPaused() public {
        marketManagerIsolated.setBorrowPaused(address(eUSDCIsolated), true);

        vm.prank(address(eUSDCIsolated)); // prank as eUSDCIsolated to call setBorrowPaused

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canBorrowWithNotify(address(eUSDCIsolated), user1, 100e6);
    }

    function test_canBorrowNotify_fail_whenInsufficientLiquidity() public {

        vm.warp(gaugeManager.gaugeStartTime());

        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );

        chainlinkUsdcEth.updateRoundData(
            0,
            1e18,
            block.timestamp,
            block.timestamp
        );

        vm.prank(address(eUSDCIsolated));

        vm.expectRevert(MarketManagerIsolated.MarketManager__InsufficientCollateral.selector);
        marketManagerIsolated.canBorrowWithNotify(address(eUSDCIsolated), user1, 100e6);


    }

    function test_canBorrowWithNotify_fail_whenInsufficientLoanSize() public {
        vm.warp(gaugeManager.gaugeStartTime());

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        chainlinkEthUsd.updateRoundData(
            0,
            1500e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcEth.updateRoundData(
            0,
            1500e18,
            block.timestamp,
            block.timestamp
        );

        marketManagerIsolated.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000     // baseCFactor 20%
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETHIsolated);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setPTokenCollateralCaps(tokens, caps);

        _prepareBALRETH(user1, 1_000e18);

        vm.startPrank(user1);
        balRETH.approve(address(pBALRETHIsolated), 1_000e18);
        pBALRETHIsolated.deposit(10e18, user1);
        marketManagerIsolated.postCollateral(user1, address(pBALRETHIsolated), 10e18);
        vm.stopPrank();

        vm.prank(address(eUSDCIsolated));

        vm.expectRevert(LiquidityManager.LiquidityManager__InsufficientLoanSize.selector);
        // borrow below the minimum loan size
        marketManagerIsolated.canBorrowWithNotify(address(eUSDCIsolated), user1, 10e6);
    }

    function test_canBorrowWithNotify_Success_whenSufficientLiquidity() public {
        vm.warp(gaugeManager.gaugeStartTime());

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        chainlinkEthUsd.updateRoundData(
            0,
            1500e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcEth.updateRoundData(
            0,
            1500e18,
            block.timestamp,
            block.timestamp
        );

        marketManagerIsolated.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000     // baseCFactor 20%
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETHIsolated);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setPTokenCollateralCaps(tokens, caps);

        _prepareBALRETH(user1, 1_000e18);

        vm.startPrank(user1);
        balRETH.approve(address(pBALRETHIsolated), 1_000e18);
        pBALRETHIsolated.deposit(10e18, user1);
        marketManagerIsolated.postCollateral(user1, address(pBALRETHIsolated), 10e18);
        vm.stopPrank();

        vm.prank(address(eUSDCIsolated));

        // minimum loan size is 50e6
        marketManagerIsolated.canBorrowWithNotify(address(eUSDCIsolated), user1, 50e6);
    
        uint256 cooldownTimestamp = marketManagerIsolated.accountAssets(user1);
        uint256 expectedCooldownTimestamp;
        assertEq(cooldownTimestamp, block.timestamp);

        vm.expectRevert(MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector);
        marketManagerIsolated.canRepay(address(eUSDCIsolated), user1);

        vm.warp(block.timestamp + 20 minutes);

        marketManagerIsolated.canRepay(address(eUSDCIsolated), user1);
   
    }



}