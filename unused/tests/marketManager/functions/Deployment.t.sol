// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManager } from "../TestBaseMarketManager.sol";


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

    function test_marketManagerDeployment_success() public {
        marketManager = new MarketManager(
            ICentralRegistry(address(centralRegistry))
        );

        assertEq(address(borrowableCUSDC.centralRegistry()), address(centralRegistry));
    }
}
