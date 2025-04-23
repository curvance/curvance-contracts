// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract MarketManagerSetAtlasDAppControlTest is TestBaseMarket {
    MarketManagerIsolated internal _marketManager;

    function setUp() public override {
        super.setUp();
    }

    function test_marketManagerAddAuthorizedAtlasDAppControl_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.addAuthorizedAtlasDAppControl(address(1));
    }

    function test_marketManagerAddAuthorizedAtlasDAppControl_success() public {
        assertEq(marketManagerIsolated.hasAtlasPermissions(address(1)), false);

        marketManagerIsolated.addAuthorizedAtlasDAppControl(address(1));

        assertEq(marketManagerIsolated.hasAtlasPermissions(address(1)), true);

        marketManagerIsolated.addAuthorizedAtlasDAppControl(address(0));

        assertEq(marketManagerIsolated.hasAtlasPermissions(address(1)), true);

        marketManagerIsolated.removeAuthorizedAtlasDAppControl(address(1));

        assertEq(marketManagerIsolated.hasAtlasPermissions(address(1)), false);
    }

    function test_marketManagerRemoveAuthorizedAtlasDAppControl_fail_whenCallerIsNotAuthorized() public {
        marketManagerIsolated.addAuthorizedAtlasDAppControl(address(1));
        vm.prank(address(2));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.unlockAtlasCollateral(address(1));
    }

    function test_marketManagerLockAtlasCollateral_fail_whenCallerIsNotAuthorized() public {
        marketManagerIsolated.addAuthorizedAtlasDAppControl(address(1));
        vm.prank(address(2));

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        marketManagerIsolated.lockAtlasCollateral();
    }

    function test_marketManagerUnlockAtlasCollateral_success() public {
        marketManagerIsolated.addAuthorizedAtlasDAppControl(address(5));

        assertEq(marketManagerIsolated.hasAtlasPermissions(address(5)), true);

        vm.prank(address(5));
        marketManagerIsolated.unlockAtlasCollateral(address(1));

        vm.prank(address(5));
        marketManagerIsolated.lockAtlasCollateral();
    }
}
