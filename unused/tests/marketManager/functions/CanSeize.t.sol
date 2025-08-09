// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract CanSeizeTest is TestBaseMarketManager {
    function test_canSeize_fail_whenPaused() public {
        marketManager.setSeizePaused(true);

        vm.expectRevert(MarketManager.MarketManager__Paused.selector);
        marketManager.canSeize(address(simpleCBALRETH), address(borrowableCUSDC));
    }

    function test_canSeize_fail_whenPTokenNotListed() public {
        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canSeize(address(simpleCBALRETH), address(borrowableCUSDC));
    }

    function test_canSeize_fail_whenETokenNotListed() public {
        marketManager.listToken(address(simpleCBALRETH));

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        marketManager.canSeize(address(simpleCBALRETH), address(borrowableCUSDC));
    }

    function test_canSeize_success() public {
        marketManager.listToken(address(simpleCBALRETH));
        marketManager.listToken(address(borrowableCUSDC));

        marketManager.canSeize(address(simpleCBALRETH), address(borrowableCUSDC));
    }

    // function test_canSeize_fail_whenMarketManagersMismatch() public {
    //     marketManager.listToken(address(simpleCBALRETH));
    //     marketManager.listToken(address(borrowableCUSDC));

    //     MarketManager newMarketManager = new MarketManager(
    //         ICentralRegistry(address(centralRegistry)),
    //         address(gaugeManager)
    //     );
    //     centralRegistry.addLendingMarket(address(newMarketManager), 1000);
    //     borrowableCUSDC.setMarketManager(address(newMarketManager));

    //     vm.expectRevert(MarketManager.MarketManager__MarketManagerMismatch.selector);
    //     marketManager.canSeize(address(simpleCBALRETH), address(borrowableCUSDC));
    // }
}
