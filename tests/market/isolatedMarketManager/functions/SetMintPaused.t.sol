// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract SetMintPausedTest is TestBaseMarketManagerIsolated {
    event TokenActionPaused(address cToken, string action, bool pauseState);

    function test_setMintPaused_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.setMintPaused(address(eUSDC), true);
    }

    function test_setMintPaused_fail_whenCTokenIsNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canMint(address(eUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.setMintPaused(address(eUSDC), true);
    }

    function test_setMintPaused_success() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(pBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(eUSDC), 77777);

        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));

        marketManagerIsolated.canMint(address(eUSDC));

        assertEq(marketManagerIsolated.mintPaused(address(eUSDC)), 0);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit TokenActionPaused(address(eUSDC), "Mint Paused", true);

        marketManagerIsolated.setMintPaused(address(eUSDC), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canMint(address(eUSDC));

        assertEq(marketManagerIsolated.mintPaused(address(eUSDC)), 2);

        vm.expectEmit(true, true, true, true, address(marketManagerIsolated));
        emit TokenActionPaused(address(eUSDC), "Mint Paused", false);

        marketManagerIsolated.setMintPaused(address(eUSDC), false);

        assertEq(marketManagerIsolated.mintPaused(address(eUSDC)), 1);
    }
}
