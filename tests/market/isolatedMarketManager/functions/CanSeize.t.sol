// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract CanSeizeTest is TestBaseMarketManagerIsolated {
    function test_canSeize_fail_whenPaused() public {
        marketManagerIsolated.setSeizePaused(true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        marketManagerIsolated.canSeize(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    function test_canSeize_fail_whenPTokenNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canSeize(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    function test_canSeize_fail_whenETokenNotListed() public {
        // deal(address(balRETH), address(this), 77777);
        // balRETH.approve(address(strategyCBALRETH), 77777);

        // deal(address(_USDC_ADDRESS), address(this), 77777);
        // usdc.approve(address(borrowableCUSDC), 77777);

        // marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canSeize(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    function test_canSeize_success() public {
        deal(address(balRETH), address(this), 77777);
        balRETH.approve(address(strategyCBALRETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        marketManagerIsolated.canSeize(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    // not possible to reach this code path
    // function test_canSeize_fail_whenMarketManagersMismatch() public {
    //     marketManagerIsolated.listToken(address(strategyCBALRETH));
    //     marketManagerIsolated.listToken(address(borrowableCUSDC));

    //     MarketManager newMarketManager = new MarketManager(
    //         ICentralRegistry(address(centralRegistry)),
    //         address(gaugeManager)
    //     );
    //     centralRegistry.addLendingMarket(address(newMarketManager), 1000);
    //     borrowableCUSDC.setMarketManager(address(newMarketManager));

    //     vm.expectRevert(MarketManagerIsolated.MarketManager__MarketManagerMismatch.selector);
    //     marketManagerIsolated.canSeize(address(strategyCBALRETH), address(borrowableCUSDC));
    // }
}
