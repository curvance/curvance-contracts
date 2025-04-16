// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract CentralRegistrySetAtlasDAppControlTest is TestBaseMarket {
    // MarketManager[] internal _marketManagers;

    // function setUp() public override {
    //     super.setUp();
    // }

    // function test_centralRegistryAddAuthorizedAtlasDAppControl_fail_whenCallerIsNotAuthorized()
    //     public
    // {
    //     vm.prank(address(1));

    //     vm.expectRevert(CentralRegistry.CentralRegistry__Unauthorized.selector);
    //     centralRegistry.addAuthorizedAtlasDAppControl(address(1));
    // }

    // function test_centralRegistryAddAuthorizedAtlasDAppControl_success() public {
    //     assertEq(centralRegistry.hasAtlasPermissions(address(1)), false);

    //     centralRegistry.addAuthorizedAtlasDAppControl(address(1));

    //     assertEq(centralRegistry.hasAtlasPermissions(address(1)), true);

    //     centralRegistry.addAuthorizedAtlasDAppControl(address(0));

    //     assertEq(centralRegistry.hasAtlasPermissions(address(1)), true);

    //     centralRegistry.removeAuthorizedAtlasDAppControl(address(1));

    //     assertEq(centralRegistry.hasAtlasPermissions(address(1)), false);
    // }

    // function test_centralRegistryRemoveAuthorizedAtlasDAppControl_fail_whenCallerIsNotAuthorized() public {
    //     centralRegistry.addAuthorizedAtlasDAppControl(address(1));
    //     vm.prank(address(2));

    //     vm.expectRevert(CentralRegistry.CentralRegistry__Unauthorized.selector);
    //     centralRegistry.unlockAtlasOev();
    // }

    // function test_centralRegistryLockAtlasOev_fail_whenCallerIsNotAuthorized() public {
    //     centralRegistry.addAuthorizedAtlasDAppControl(address(1));
    //     vm.prank(address(2));

    //     vm.expectRevert(CentralRegistry.CentralRegistry__Unauthorized.selector);
    //     centralRegistry.lockAtlasOev();
    // }

    // function test_centralRegistryLockUnlockAtlasOev_success() public {
    //     centralRegistry.addAuthorizedAtlasDAppControl(address(5));

    //     assertEq(centralRegistry.isAtlasOevAllowed(), false);

    //     vm.prank(address(5));
    //     centralRegistry.unlockAtlasOev();

    //     assertEq(centralRegistry.isAtlasOevAllowed(), true);

    //     vm.prank(address(5));
    //     centralRegistry.lockAtlasOev();

    //     assertEq(centralRegistry.isAtlasOevAllowed(), false);

    // }
}
