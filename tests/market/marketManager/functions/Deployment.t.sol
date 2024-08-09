// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { LiquidityManager } from "contracts/market/LiquidityManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract MarketManagerDeploymentTest is TestBaseMarketManager {
    function test_marketManagerDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            LiquidityManager.LiquidityManager__InvalidParameter.selector
        );
        new MarketManager(ICentralRegistry(address(0)));
    }

    function test_marketManagerDeployment_fail_whenGaugePoolIsZeroAddress()
        public
    {
        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        new MarketManager(
            ICentralRegistry(address(centralRegistry))
        );
    }

    function test_marketManagerDeployment_success() public {
        marketManager = new MarketManager(
            ICentralRegistry(address(centralRegistry))
        );

        assertEq(address(dUSDC.centralRegistry()), address(centralRegistry));
    }
}
