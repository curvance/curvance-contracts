// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MarketManagerIsolated, LiquidityManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract IsolatedMarketManagerDeploymentTest is TestBaseMarketIsolated {
    function test_marketManagerDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            LiquidityManagerIsolated.LiquidityManager__InvalidParameter.selector
        );
        new MarketManagerIsolated(ICentralRegistry(address(0)));
    }

    function test_marketManagerDeployment_success() public {
        marketManagerIsolated = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry))
        );

        assertEq(address(borrowableCUSDC.centralRegistry()), address(centralRegistry));
    }
}
