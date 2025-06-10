// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract CanMintTest is TestBaseMarketManagerIsolated {
    function test_canMint_fail_whenMintPaused() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(pBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(eUSDC), 77777);

        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));

        marketManagerIsolated.setMintPaused(address(eUSDC), true);
        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canMint(address(eUSDC));
    }

    function test_canMint_fail_whenTokenNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canMint(address(eUSDC));
    }

    function test_canMint_success() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(pBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(eUSDC), 77777);

        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));
        marketManagerIsolated.canMint(address(eUSDC));
    }
}
