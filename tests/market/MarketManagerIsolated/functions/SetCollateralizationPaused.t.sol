// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract SetCollateralizationPausedTest is TestBaseMarketIsolated {
    event TokenActionPaused(address cToken, string action, bool pauseState);

    function test_setCollateralizationPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setCollateralizationPaused(address(borrowableCUSDC), true);
    }

    function test_setCollateralizationPaused_fail_whenCTokenIsNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.setCollateralizationPaused(address(borrowableCUSDC), true);
    }

    function test_setCollateralizationPaused_success() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        assertFalse(_collateralizationPaused(address(borrowableCUSDC)));

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit TokenActionPaused(address(borrowableCUSDC), "Collateralization Paused", true);

        marketManagerIsolated.setCollateralizationPaused(address(borrowableCUSDC), true);

        assertTrue(_collateralizationPaused(address(borrowableCUSDC)));

        vm.startPrank(address(borrowableCUSDC));
        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canCollateralize(address(borrowableCUSDC), user1,  1);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit TokenActionPaused(address(borrowableCUSDC), "Collateralization Paused", false);

        marketManagerIsolated.setCollateralizationPaused(address(borrowableCUSDC), false);

        assertFalse(_collateralizationPaused(address(borrowableCUSDC)));
    }

    function _collateralizationPaused(address cToken) internal returns (bool isPaused) {
        (, isPaused, ) = marketManagerIsolated.actionsPaused(cToken);
    }
}
