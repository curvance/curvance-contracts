// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract CentralRegistrySetBundlerTest is TestBaseMarket {
    MarketManager[] internal _marketManagers;

    function setUp() public override {
        super.setUp();

        centralRegistry.removeMarketManager(address(marketManager));

        for (uint256 i = 0; i < 10; i++) {
            _marketManagers.push(
                new MarketManager(ICentralRegistry(address(centralRegistry)))
            );
            centralRegistry.addMarketManager(
                address(_marketManagers[i]),
                marketInterestFactor
            );
        }
    }

    function test_centralRegistrySetBundler_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setBundler(address(1), true);
    }

    function test_centralRegistrySetBundler_success() public {
        for (uint256 i = 0; i < 10; i++) {
            assertFalse(_marketManagers[i].liquidationBundlers(address(1)));
        }

        centralRegistry.setBundler(address(1), true);

        for (uint256 i = 0; i < 10; i++) {
            assertTrue(_marketManagers[i].liquidationBundlers(address(1)));
        }

        centralRegistry.setBundler(address(1), false);

        for (uint256 i = 0; i < 10; i++) {
            assertFalse(_marketManagers[i].liquidationBundlers(address(1)));
        }
    }
}
