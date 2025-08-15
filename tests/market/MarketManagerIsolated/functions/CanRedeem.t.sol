// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { ILiquidityManager } from "contracts/interfaces/ILiquidityManager.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract CanRedeemTest is TestBaseMarketIsolated {
    function setUp() public override {
        super.setUp();

        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    function test_canRedeem_fail_whenTokenNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canRedeem(address(borrowableCDAI), 100e6, user1);
    }

    function test_canRedeem_fail_whenTransferIsDisabled() public {
        vm.prank(user1);
        centralRegistry.setTransferableStatus(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canRedeem(address(borrowableCUSDC), 100e6, user1);
    }

    function test_canRedeem_fail_whenCooldownIsNotEnded() public {
        vm.startPrank(user1);

        centralRegistry.setCooldown(10 days);
        centralRegistry.setCooldown(5 days);

        vm.stopPrank();

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canRedeem(address(borrowableCUSDC), 100e6, user1);
    }

    function test_canRedeem_fail_whenWithinMinimumHoldPeriod() public {
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.notifyBorrow(address(borrowableCUSDC), user1);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        marketManagerIsolated.canRedeem(address(borrowableCUSDC), 100e6, user1);
    }

    function test_canRedeem_fail_whenCInsufficientLiquidity() public {
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);

        _prepareBALRETH(user1, 10_000e18);
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1_000e18);
        strategyCBALRETH.deposit(1e18, user1);
        strategyCBALRETH.postCollateral(9e17);
        vm.stopPrank();

        bool hasPosition = ILiquidityManager(address(marketManagerIsolated))
            .accountPositions(address(strategyCBALRETH), user1) == 2;

        assertTrue(hasPosition);

        skip(20 minutes);

        borrowableCUSDC.accrueIfNeeded();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        marketManagerIsolated.canRedeem(address(strategyCBALRETH), 100e18, user1);
    }

    function test_canRedeem_success_whenPastMinimumHoldPeriod() public {
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.notifyBorrow(address(borrowableCUSDC), user1);

        skip(20 minutes);

        borrowableCUSDC.accrueIfNeeded();

        marketManagerIsolated.canRedeem(address(borrowableCUSDC), 100e6, user1);
    }

    function test_canRedeem_success_whenRedeemerHasNoPosition() public {
        bool hasPosition = ILiquidityManager(address(marketManagerIsolated))
            .accountPositions(address(borrowableCUSDC), user1) == 2;

        assertFalse(hasPosition);
        marketManagerIsolated.canRedeem(address(borrowableCUSDC), 100e6, user1);
    }
}
