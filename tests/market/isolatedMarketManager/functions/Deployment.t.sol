// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManagerIsolated, LiquidityManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract MarketManagerDeploymentTest is TestBaseMarketManagerIsolated {
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

        assertEq(address(eUSDC.centralRegistry()), address(centralRegistry));
    }
}
