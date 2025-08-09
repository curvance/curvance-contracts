// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract SetMintPausedTest is TestBaseMarketIsolated {
    event TokenActionPaused(address cToken, string action, bool pauseState);

    function test_setMintPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setMintPaused(address(borrowableCUSDC), true);
    }

    function test_setMintPaused_fail_whenCTokenIsNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.setMintPaused(address(borrowableCUSDC), true);
    }

    function test_setMintPaused_success() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        marketManagerIsolated.canMint(address(borrowableCUSDC));

        assertFalse(_mintPaused(address(borrowableCUSDC)));

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit TokenActionPaused(address(borrowableCUSDC), "Mint Paused", true);

        marketManagerIsolated.setMintPaused(address(borrowableCUSDC), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canMint(address(borrowableCUSDC));

        assertTrue(_mintPaused(address(borrowableCUSDC)));

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit TokenActionPaused(address(borrowableCUSDC), "Mint Paused", false);

        marketManagerIsolated.setMintPaused(address(borrowableCUSDC), false);

        assertFalse(_mintPaused(address(borrowableCUSDC)));
    }

    function _mintPaused(address cToken) internal returns (bool isPaused) {
        (isPaused, , ) = marketManagerIsolated.actionsPaused(cToken);
    }
}
