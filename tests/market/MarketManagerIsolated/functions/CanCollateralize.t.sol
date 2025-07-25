// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract CanCollateralizeTest is TestBaseMarketIsolated {
    function setUp() public override {
        super.setUp();

        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100_000e6);
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e6, 0);
    }

    function test_canCollateralize_fail_whenTokenNotListed() public {
        vm.startPrank(address(borrowableCDAI));

        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        marketManagerIsolated.canCollateralize(address(borrowableCDAI), user1, 1e6);

        vm.stopPrank();
    }

    function test_canCollateralize_fail_whenUnauthorized() public {
        vm.startPrank(user1);
        
        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.canCollateralize(address(borrowableCUSDC), user1, 1e6);

        vm.stopPrank();
    }

    function test_canCollateralize_fail_whenCollateralCapFull() public {
        _prepareUSDC(user1, 10e6);

        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), 1e6);
        borrowableCUSDC.deposit(1e6, user1);
        vm.stopPrank();

        vm.startPrank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        marketManagerIsolated.canCollateralize(address(borrowableCUSDC), user1, 1e6);

        vm.stopPrank();
    }

    function test_canCollateralize_fail_whenCollateralizationIsPaused() public {
        marketManagerIsolated.setCollateralizationPaused(address(borrowableCUSDC), true);

        vm.startPrank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canCollateralize(address(borrowableCUSDC), user1, 1e6);

        vm.stopPrank();
    }

    function test_canCollateralize_success() public {
        _prepareUSDC(user1, 10e6);

        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), 1e6);
        borrowableCUSDC.deposit(1e6, user1);
        vm.stopPrank();

        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e6, 100_000e6);

        vm.startPrank(address(borrowableCUSDC));

        marketManagerIsolated.canCollateralize(address(borrowableCUSDC), user1, 1e6);

        vm.stopPrank();

        bool hasPosition;
        (hasPosition, , ) = auxiliaryData.tokenDataOf(user1, address(borrowableCUSDC));

        assertTrue(hasPosition);
    }
}
