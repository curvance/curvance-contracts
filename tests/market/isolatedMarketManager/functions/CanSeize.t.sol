// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract CanSeizeTest is TestBaseMarketManagerIsolated {
    function test_canSeize_fail_whenPaused() public {
        marketManagerIsolated.setSeizePaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canSeize(address(pBALRETH), address(eUSDC));
    }

    function test_canSeize_fail_whenPTokenNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canSeize(address(pBALRETH), address(eUSDC));
    }

    function test_canSeize_fail_whenETokenNotListed() public {
        // deal(address(balRETH), address(this), 77777);
        // balRETH.approve(address(pBALRETH), 77777);

        // deal(address(_USDC_ADDRESS), address(this), 77777);
        // usdc.approve(address(eUSDC), 77777);

        // marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canSeize(address(pBALRETH), address(eUSDC));
    }

    function test_canSeize_success() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(pBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(eUSDC), 77777);

        marketManagerIsolated.listTokens(address(pBALRETH), address(eUSDC));

        marketManagerIsolated.canSeize(address(pBALRETH), address(eUSDC));
    }

    // not possible to reach this code path
    // function test_canSeize_fail_whenMarketManagersMismatch() public {
    //     marketManagerIsolated.listToken(address(pBALRETH));
    //     marketManagerIsolated.listToken(address(eUSDC));

    //     MarketManager newMarketManager = new MarketManager(
    //         ICentralRegistry(address(centralRegistry)),
    //         address(gaugeManager)
    //     );
    //     centralRegistry.addLendingMarket(address(newMarketManager), 1000);
    //     eUSDC.setMarketManager(address(newMarketManager));

    //     vm.expectRevert(MarketManagerIsolated.MarketManager__MarketManagerMismatch.selector);
    //     marketManagerIsolated.canSeize(address(pBALRETH), address(eUSDC));
    // }
}
