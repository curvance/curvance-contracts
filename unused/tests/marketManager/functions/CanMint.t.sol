// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";


contract CanMintTest is TestBaseMarketManager {
    function test_canMint_fail_whenMintPaused() public {
        marketManager.listToken(address(borrowableCUSDC));

        marketManager.setMintPaused(address(borrowableCUSDC), true);
        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        marketManager.canMint(address(borrowableCUSDC));
    }

    function test_canMint_fail_whenTokenNotListed() public {
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canMint(address(borrowableCUSDC));
    }

    function test_canMint_success() public {
        marketManager.listToken(address(borrowableCUSDC));
        marketManager.canMint(address(borrowableCUSDC));
    }
}
