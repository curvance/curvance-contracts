// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

import { console2 } from "forge-std/console2.sol";

contract TransferEmergencyCouncilTest is TestBaseMarketIsolated {
    address public newCouncil1 = address(1001);
    address public newCouncil2 = address(1002);

    event PermissionsTransferred(
        string indexed permissionsType,
        address previousEmergencyCouncil,
        address newEmergencyCouncil
    );

    function test_transferEmergencyCouncil_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.transferEmergencyCouncil(newCouncil1);
    }

    function test_transferEmergencyCouncil_success() public {
        assertTrue(centralRegistry.hasDaoPermissions(address(this)));
        assertTrue(centralRegistry.hasElevatedPermissions(address(this)));

        vm.expectEmit(true, true, true, true);
        emit PermissionsTransferred(
            "Emergency Council",
            address(this),
            newCouncil1
        );

        centralRegistry.transferEmergencyCouncil(newCouncil1);

        assertTrue(centralRegistry.hasDaoPermissions(newCouncil1));
        assertTrue(centralRegistry.hasDaoPermissions(address(this)));

        assertTrue(centralRegistry.hasMarketPermissions(newCouncil1));
        assertTrue(centralRegistry.hasElevatedPermissions(newCouncil1));
        
        assertFalse(centralRegistry.hasMarketPermissions(address(this)));
        assertFalse(centralRegistry.hasElevatedPermissions(address(this)));

        vm.expectEmit(true, true, true, true);
        emit PermissionsTransferred(
            "Emergency Council",
            newCouncil1,
            newCouncil2
        );

        vm.prank(newCouncil1);
        centralRegistry.transferEmergencyCouncil(newCouncil2);

        assertTrue(centralRegistry.hasDaoPermissions(newCouncil2));
        assertTrue(centralRegistry.hasMarketPermissions(newCouncil2));
        assertTrue(centralRegistry.hasElevatedPermissions(newCouncil2));

        assertFalse(centralRegistry.hasDaoPermissions(newCouncil1));
        assertFalse(centralRegistry.hasMarketPermissions(newCouncil1));
        assertFalse(centralRegistry.hasElevatedPermissions(newCouncil1));
    }
}
