// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerIsolated } from "../TestBaseMarketManagerIsolated.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { LiquidityManager } from "contracts/market/LiquidityManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract MarketManagerDeploymentTest is TestBaseMarketManagerIsolated {
    function test_marketManagerDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            LiquidityManager.LiquidityManager__InvalidParameter.selector
        );
        new MarketManager(ICentralRegistry(address(0)));
    }

    function test_marketManagerDeployment_success() public {
        marketManager = new MarketManager(
            ICentralRegistry(address(centralRegistry))
        );

        assertEq(address(eUSDC.centralRegistry()), address(centralRegistry));
    }
}
