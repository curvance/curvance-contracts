// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract IsolatedMarketManagerDeploymentTest is TestBaseMarketIsolated {
    function test_marketManagerDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry
                .selector
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
