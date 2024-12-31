// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract CentralRegistrySetAtlasDAppControlTest is TestBaseMarket {
    MarketManager[] internal _marketManagers;

    function setUp() public override {
        super.setUp();
    }

    function test_centralRegistrySetAuthorizedAtlasDAppControl_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(CentralRegistry.CentralRegistry__Unauthorized.selector);
        centralRegistry.setAuthorizedAtlasDAppControl(address(1));
    }

    function test_centralRegistrySetAuthorizedAtlasDAppControl_success() public {
        assertEq(centralRegistry.authorizedAtlasDAppControl(), address(0));

        centralRegistry.setAuthorizedAtlasDAppControl(address(1));

        assertEq(centralRegistry.authorizedAtlasDAppControl(), address(1));

        centralRegistry.setAuthorizedAtlasDAppControl(address(0));

        assertEq(centralRegistry.authorizedAtlasDAppControl(), address(0));
    }

    function test_centralRegistryUnlockAtlasOev_fail_whenCallerIsNotAuthorized() public {
        centralRegistry.setAuthorizedAtlasDAppControl(address(1));
        vm.prank(address(2));

        vm.expectRevert(CentralRegistry.CentralRegistry__Unauthorized.selector);
        centralRegistry.unlockAtlasOev();
    }

    function test_centralRegistryLockAtlasOev_fail_whenCallerIsNotAuthorized() public {
        centralRegistry.setAuthorizedAtlasDAppControl(address(1));
        vm.prank(address(2));

        vm.expectRevert(CentralRegistry.CentralRegistry__Unauthorized.selector);
        centralRegistry.lockAtlasOev();
    }

    function test_centralRegistryLockUnlockAtlasOev_success() public {
        centralRegistry.setAuthorizedAtlasDAppControl(address(5));

        assertEq(centralRegistry.atlasOevAllowed(), false);

        vm.prank(address(5));
        centralRegistry.unlockAtlasOev();

        assertEq(centralRegistry.atlasOevAllowed(), true);

        vm.prank(address(5));
        centralRegistry.lockAtlasOev();

        assertEq(centralRegistry.atlasOevAllowed(), false);

    }
}
