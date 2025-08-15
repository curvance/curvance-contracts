// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";


contract SetMintPausedTest is TestBaseMarketManager {
    event TokenActionPaused(address mToken, string action, bool pauseState);

    function test_setMintPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManager.MarketManager__Unauthorized.selector);
        marketManager.setMintPaused(address(borrowableCUSDC), true);
    }

    function test_setMintPaused_fail_whenMTokenIsNotListed() public {
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canMint(address(borrowableCUSDC));

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.setMintPaused(address(borrowableCUSDC), true);
    }

    function test_setMintPaused_success() public {
        marketManager.listToken(address(borrowableCUSDC));

        marketManager.canMint(address(borrowableCUSDC));

        assertEq(marketManager.mintPaused(address(borrowableCUSDC)), 0);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit TokenActionPaused(address(borrowableCUSDC), "Mint Paused", true);

        marketManager.setMintPaused(address(borrowableCUSDC), true);

        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        marketManager.canMint(address(borrowableCUSDC));

        assertEq(marketManager.mintPaused(address(borrowableCUSDC)), 2);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit TokenActionPaused(address(borrowableCUSDC), "Mint Paused", false);

        marketManager.setMintPaused(address(borrowableCUSDC), false);

        assertEq(marketManager.mintPaused(address(borrowableCUSDC)), 1);
    }
}
