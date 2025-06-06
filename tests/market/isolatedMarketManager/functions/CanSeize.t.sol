// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract CanSeizeTest is TestBaseMarketManagerIsolated {
    function test_canSeize_fail_whenPaused() public {
        marketManager.setSeizePaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManager.canSeize(address(pBALRETH), address(eUSDC));
    }

    function test_canSeize_fail_whenPTokenNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManager.canSeize(address(pBALRETH), address(eUSDC));
    }

    function test_canSeize_fail_whenETokenNotListed() public {
        // deal(address(balRETH), address(this), 42069);
        // balRETH.approve(address(pBALRETH), 42069);

        // deal(address(_USDC_ADDRESS), address(this), 42069);
        // usdc.approve(address(eUSDC), 42069);

        // marketManager.listTokens(address(pBALRETH), address(eUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManager.canSeize(address(pBALRETH), address(eUSDC));
    }

    function test_canSeize_success() public {
        deal(address(balRETH), address(this), 42069);
        balRETH.approve(address(pBALRETH), 42069);

        deal(address(_USDC_ADDRESS), address(this), 42069);
        usdc.approve(address(eUSDC), 42069);

        marketManager.listTokens(address(pBALRETH), address(eUSDC));

        marketManager.canSeize(address(pBALRETH), address(eUSDC));
    }

    // not possible to reach this code path
    // function test_canSeize_fail_whenMarketManagersMismatch() public {
    //     marketManager.listToken(address(pBALRETH));
    //     marketManager.listToken(address(eUSDC));

    //     MarketManager newMarketManager = new MarketManager(
    //         ICentralRegistry(address(centralRegistry)),
    //         address(gaugeManager)
    //     );
    //     centralRegistry.addLendingMarket(address(newMarketManager), 1000);
    //     eUSDC.setMarketManager(address(newMarketManager));

    //     vm.expectRevert(MarketManagerIsolated.MarketManager__MarketManagerMismatch.selector);
    //     marketManager.canSeize(address(pBALRETH), address(eUSDC));
    // }
}
