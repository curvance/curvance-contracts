// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract CanRedeemTest is TestBaseMarketManagerIsolated {
    function setUp() public override {
        super.setUp();

        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(simpleCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(simpleCBALRETH), address(borrowableCUSDC));
    }

    function test_canRedeem_fail_whenTokenNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canRedeem(address(borrowableCDAI), user1, 100e6);
    }

    function test_canRedeem_fail_whenTransferIsDisabled() public {
        vm.prank(user1);
        centralRegistry.setTransferableStatus(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canRedeem(address(borrowableCUSDC), user1, 100e6);
    }

    function test_canRedeem_fail_whenCooldownIsNotEnded() public {
        vm.startPrank(user1);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canRedeem(address(borrowableCUSDC), user1, 100e6);
    }

    function test_canRedeem_fail_whenWithinMinimumHoldPeriod() public {
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.notifyBorrow(address(borrowableCUSDC), user1);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        marketManagerIsolated.canRedeem(address(borrowableCUSDC), user1, 100e6);
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
        // marketManager.listToken(address(simpleCBALRETH));
        _setCTokenConfigBasic(address(simpleCBALRETH), 100_000e18, 0);

        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(simpleCBALRETH), 1_000e18);
        simpleCBALRETH.deposit(1e18, user1);
        simpleCBALRETH.postCollateral(9e17);
        vm.stopPrank();

        bool hasPosition;
        (hasPosition, , ) = auxiliaryData.tokenDataOf(
            user1,
            address(simpleCBALRETH)
        );

        assertTrue(hasPosition);

        skip(20 minutes);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        marketManagerIsolated.canRedeem(address(simpleCBALRETH), user1, 100e18);
    }

    function test_canRedeem_success_whenPastMinimumHoldPeriod() public {
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.notifyBorrow(address(borrowableCUSDC), user1);

        skip(20 minutes);
        marketManagerIsolated.canRedeem(address(borrowableCUSDC), user1, 100e6);
    }

    function test_canRedeem_success_whenRedeemerNotInMarket() public {
        bool hasPosition;
        (hasPosition, , ) = auxiliaryData.tokenDataOf(user1, address(borrowableCUSDC));

        assertFalse(hasPosition);
        marketManagerIsolated.canRedeem(address(borrowableCUSDC), user1, 100e6);
    }

    function test_canRedeem_success_ETokenCanAlwaysBeRedeemed() public {
        assertTrue(borrowableCUSDC.isBorrowable());
        marketManagerIsolated.canRedeem(address(borrowableCUSDC), user1, 100e6);
    }
}
