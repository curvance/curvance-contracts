// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetMulticallProvidersTest is TestBaseMarketIsolated {
    address[] public providers;

    function setUp() public override {
        super.setUp();

        for (uint256 i = 0; i < 10; i++) {
            providers.push(address(uint160(i)));
        }
    }

    function test_setMulticallProviders_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setMulticallProviders(providers, true);
    }

    function test_setMulticallProviders_fail_whenAlreadyNotSupported() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.setMulticallProviders(providers, false);
    }

    function test_setMulticallProviders_fail_whenAlreadySupported() public {
        centralRegistry.setMulticallProviders(providers, true);

        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.setMulticallProviders(providers, true);
    }

    function test_setMulticallProviders_success() public {
        for (uint256 i = 0; i < 10; i++) {
            assertFalse(centralRegistry.isMulticallProvider(providers[i]));
        }

        centralRegistry.setMulticallProviders(providers, true);

        for (uint256 i = 0; i < 10; i++) {
            assertTrue(centralRegistry.isMulticallProvider(providers[i]));
        }
    }
}
