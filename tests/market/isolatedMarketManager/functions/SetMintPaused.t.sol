// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract SetMintPausedTest is TestBaseMarketManagerIsolated {
    event TokenActionPaused(address mToken, string action, bool pauseState);

    function test_setMintPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManager.setMintPaused(address(eUSDC), true);
    }

    function test_setMintPaused_fail_whenMTokenIsNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManager.canMint(address(eUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManager.setMintPaused(address(eUSDC), true);
    }

    function test_setMintPaused_success() public {
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));

        marketManager.canMint(address(eUSDC));

        assertEq(marketManager.mintPaused(address(eUSDC)), 0);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit TokenActionPaused(address(eUSDC), "Mint Paused", true);

        marketManager.setMintPaused(address(eUSDC), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManager.canMint(address(eUSDC));

        assertEq(marketManager.mintPaused(address(eUSDC)), 2);

        vm.expectEmit(true, true, true, true, address(marketManager));
        emit TokenActionPaused(address(eUSDC), "Mint Paused", false);

        marketManager.setMintPaused(address(eUSDC), false);

        assertEq(marketManager.mintPaused(address(eUSDC)), 1);
    }
}
