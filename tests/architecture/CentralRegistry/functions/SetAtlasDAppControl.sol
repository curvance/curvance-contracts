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

    function test_centralRegistrySetAuthorizedAtlasDAppControl_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setAuthorizedAtlasDAppControl(address(1));
    }

    function test_centralRegistrySetAuthorizedAtlasDAppControl_success() public {
        for (uint256 i = 0; i < 10; i++) {
            assertEq(_marketManagers[i].authorizedAtlasDAppControl(), address(0));
        }

        centralRegistry.setAuthorizedAtlasDAppControl(address(1));

        for (uint256 i = 0; i < 10; i++) {
            assertEq(_marketManagers[i].authorizedAtlasDAppControl(), address(1));
        }

        centralRegistry.setAuthorizedAtlasDAppControl(address(0));

        for (uint256 i = 0; i < 10; i++) {
            assertEq(_marketManagers[i].authorizedAtlasDAppControl(), address(0));
        }
    }

    function test_centralRegistryUnlockAtlasOev_fail_whenCallerIsNotAuthorized() public {
        centralRegistry.setAuthorizedAtlasDAppControl(address(1));
        vm.prank(address(2));

        for (uint256 i = 0; i < 10; i++) {
            vm.expectRevert(MarketManager.MarketManager__InvalidAtlasDAppControl.selector);
            _marketManagers[i].unlockAtlasOev();
        }
    }

    function test_centralRegistryLockAtlasOev_fail_whenCallerIsNotAuthorized() public {
        centralRegistry.setAuthorizedAtlasDAppControl(address(1));
        vm.prank(address(2));

        for (uint256 i = 0; i < 10; i++) {
            vm.expectRevert(MarketManager.MarketManager__InvalidAtlasDAppControl.selector);
            _marketManagers[i].lockAtlasOev();
        }
    }

    function test_centralRegistryLockUnlockAtlasOev_success() public {
        centralRegistry.setAuthorizedAtlasDAppControl(address(5));

        for (uint256 i = 0; i < 10; i++) {
            assertEq(_marketManagers[i].atlasOevAllowed(), false);
        }

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(address(5));
            _marketManagers[i].unlockAtlasOev();
        }

        for (uint256 i = 0; i < 10; i++) {
            assertEq(_marketManagers[i].atlasOevAllowed(), true);
        }

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(address(5));
            _marketManagers[i].lockAtlasOev();
        }

        for (uint256 i = 0; i < 10; i++) {
            assertEq(_marketManagers[i].atlasOevAllowed(), false);
        }
    }
}
