// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract MarketManagerSetAtlasDAppControlTest is TestBaseMarketIsolated {
    MarketManagerIsolated internal _marketManager;

    function setUp() public override {
        super.setUp();
    }

    function test_marketManagerAddAuthorizedAtlasDAppControl_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(CentralRegistry.CentralRegistry__Unauthorized.selector);
        centralRegistry.addAuthorizedAtlasDAppControl(address(1));
    }

    function test_marketManagerAddAuthorizedAtlasDAppControl_success() public {
        assertEq(centralRegistry.hasAtlasPermissions(address(1)), false);

        centralRegistry.addAuthorizedAtlasDAppControl(address(1));

        assertEq(centralRegistry.hasAtlasPermissions(address(1)), true);

        centralRegistry.addAuthorizedAtlasDAppControl(address(0));

        assertEq(centralRegistry.hasAtlasPermissions(address(1)), true);

        centralRegistry.removeAuthorizedAtlasDAppControl(address(1));

        assertEq(centralRegistry.hasAtlasPermissions(address(1)), false);
    }

    function test_marketManagerRemoveAuthorizedAtlasDAppControl_fail_whenCallerIsNotAuthorized() public {
        centralRegistry.addAuthorizedAtlasDAppControl(address(1));
        vm.prank(address(2));

        vm.expectRevert(CentralRegistry.CentralRegistry__Unauthorized.selector);
        centralRegistry.removeAuthorizedAtlasDAppControl(address(1));
    }

}
