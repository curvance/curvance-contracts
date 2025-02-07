// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract CanRedeemTest is TestBaseMarketManager {
    function setUp() public override {
        super.setUp();

        marketManager.listToken(address(eUSDC));
    }

    function test_canRedeem_fail_whenTokenNotListed() public {
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canRedeem(address(pBALRETH), user1, 100e6);
    }

    function test_canRedeem_fail_whenTransferIsDisabled() public {
        vm.prank(user1);
        centralRegistry.setTransferLockStatus(true);

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.canRedeem(address(eUSDC), user1, 100e6);
    }

    function test_canRedeem_fail_whenCooldownIsNotEnded() public {
        vm.startPrank(user1);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.stopPrank();

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.canRedeem(address(eUSDC), user1, 100e6);
    }

    function test_canRedeem_fail_whenWithinMinimumHoldPeriod() public {
        vm.prank(address(eUSDC));
        marketManager.notifyBorrow(address(eUSDC), user1);

        vm.expectRevert(
            MarketManager.MarketManager__MinimumHoldPeriod.selector
        );
        marketManager.canRedeem(address(eUSDC), user1, 100e6);
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
        marketManager.listToken(address(pBALRETH));
        _setPBALRETHCollateralCaps(100_000e18);

        assertTrue(pBALRETH.isPToken());
        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1_000e18);
        pBALRETH.deposit(1e18, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 9e17);
        vm.stopPrank();

        bool hasPosition;
        (hasPosition, , ) = marketManager.tokenDataOf(
            user1,
            address(pBALRETH)
        );

        assertTrue(hasPosition);

        skip(20 minutes);
        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        marketManager.canRedeem(address(pBALRETH), user1, 100e18);
    }

    function test_canRedeem_success_whenPastMinimumHoldPeriod() public {
        vm.prank(address(eUSDC));
        marketManager.notifyBorrow(address(eUSDC), user1);

        skip(20 minutes);
        marketManager.canRedeem(address(eUSDC), user1, 100e6);
    }

    function test_canRedeem_success_whenRedeemerNotInMarket() public {
        bool hasPosition;
        (hasPosition, , ) = marketManager.tokenDataOf(user1, address(eUSDC));

        assertFalse(hasPosition);
        marketManager.canRedeem(address(eUSDC), user1, 100e6);
    }

    function test_canRedeem_success_ETokenCanAlwaysBeRedeemed() public {
        assertFalse(eUSDC.isPToken());
        marketManager.canRedeem(address(eUSDC), user1, 100e6);
    }
}
