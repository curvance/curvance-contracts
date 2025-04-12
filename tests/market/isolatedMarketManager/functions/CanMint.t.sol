// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";

contract CanMintTest is TestBaseMarketManagerIsolated {
    function test_canMint_fail_whenMintPaused() public {
        marketManager.listToken(address(eUSDC));

        marketManager.setMintPaused(address(eUSDC), true);
        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        marketManager.canMint(address(eUSDC));
    }

    function test_canMint_fail_whenTokenNotListed() public {
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canMint(address(eUSDC));
    }

    function test_canMint_success() public {
        marketManager.listToken(address(eUSDC));
        marketManager.canMint(address(eUSDC));
    }
}
