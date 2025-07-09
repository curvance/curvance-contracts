// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract CanMintTest is TestBaseMarketManagerIsolated {
    function test_canMint_fail_whenMintPaused() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(simpleCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(simpleCBALRETH), address(borrowableCUSDC));

        marketManagerIsolated.setMintPaused(address(borrowableCUSDC), true);
        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canMint(address(borrowableCUSDC));
    }

    function test_canMint_fail_whenTokenNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canMint(address(borrowableCUSDC));
    }

    function test_canMint_success() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(simpleCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(simpleCBALRETH), address(borrowableCUSDC));
        marketManagerIsolated.canMint(address(borrowableCUSDC));
    }
}
