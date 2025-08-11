// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";


contract CanRedeemTest is TestBaseMarketManager {
    function setUp() public override {
        super.setUp();

        marketManager.listToken(address(borrowableCUSDC));
    }

    function test_canRedeem_fail_whenTokenNotListed() public {
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canRedeem(address(simpleCBALRETH), user1, 100e6);
    }

    function test_canRedeem_fail_whenTransferIsDisabled() public {
        vm.prank(user1);
        centralRegistry.setTransferableStatus(true);

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.canRedeem(address(borrowableCUSDC), user1, 100e6);
    }

    function test_canRedeem_fail_whenCooldownIsNotEnded() public {
        vm.startPrank(user1);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.stopPrank();

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.canRedeem(address(borrowableCUSDC), user1, 100e6);
    }

    function test_canRedeem_fail_whenWithinMinimumHoldPeriod() public {
        vm.prank(address(borrowableCUSDC));
        marketManager.notifyBorrow(address(borrowableCUSDC), user1);

        vm.expectRevert(
            MarketManager.MarketManager__MinimumHoldPeriod.selector
        );
        marketManager.canRedeem(address(borrowableCUSDC), user1, 100e6);
    }

    function test_canRedeem_fail_whenPTokenInsufficientLiquidity() public {
        skip(gaugeManager.gaugeStartTime() - block.timestamp);

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
        marketManager.listToken(address(simpleCBALRETH));
        _setPBALRETHCollateralCaps(100_000e18);

        assertTrue(simpleCBALRETH.isPToken());
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(simpleCBALRETH), 1_000e18);
        simpleCBALRETH.deposit(1e18, user1);
        simpleCBALRETH.postCollateral(9e17);
        vm.stopPrank();

        bool hasPosition = ILiquidityManager(address(marketManagerIsolated))
            .accountPositions(address(simpleCBALRETH), user1) == 2;

        assertTrue(hasPosition);

        skip(20 minutes);
        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        marketManager.canRedeem(address(simpleCBALRETH), user1, 100e18);
    }

    function test_canRedeem_success_whenPastMinimumHoldPeriod() public {
        vm.prank(address(borrowableCUSDC));
        marketManager.notifyBorrow(address(borrowableCUSDC), user1);

        skip(20 minutes);
        marketManager.canRedeem(address(borrowableCUSDC), user1, 100e6);
    }

    function test_canRedeem_success_whenRedeemerNotInMarket() public {
        bool hasPosition = ILiquidityManager(address(marketManagerIsolated))
            .accountPositions(address(borrowableCUSDC), user1) == 2;

        assertFalse(hasPosition);
        marketManager.canRedeem(address(borrowableCUSDC), user1, 100e6);
    }

    function test_canRedeem_success_ETokenCanAlwaysBeRedeemed() public {
        assertFalse(borrowableCUSDC.isPToken());
        marketManager.canRedeem(address(borrowableCUSDC), user1, 100e6);
    }
}
