// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract CanSeizeTest is TestBaseMarketIsolated {
    function test_canSeize_fail_whenCollateralTokenNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canSeize(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));
    }

    function test_canSeize_fail_whenDebtTokenNotListed() public {
        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canSeize(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));
    }

    function test_canSeize_success() public {
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        marketManagerIsolated.canSeize(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));
    }
}
