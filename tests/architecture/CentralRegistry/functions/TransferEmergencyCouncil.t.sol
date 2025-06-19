// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

import { console2 } from "forge-std/console2.sol";

contract TransferEmergencyCouncilTest is TestBaseMarketIsolated {
    address public newEmergencyCouncil1 = address(1001);
    address public newEmergencyCouncil2 = address(1002);

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
        centralRegistry.transferEmergencyCouncil(newEmergencyCouncil1);
    }

    function test_transferEmergencyCouncil_success() public {
        assertTrue(centralRegistry.hasDaoPermissions(address(this)));
        assertTrue(centralRegistry.hasElevatedPermissions(address(this)));

        vm.expectEmit(true, true, true, true);
        emit PermissionsTransferred(
            "Emergency Council",
            address(this),
            newEmergencyCouncil1
        );

        centralRegistry.transferEmergencyCouncil(newEmergencyCouncil1);

        assertTrue(centralRegistry.hasDaoPermissions(newEmergencyCouncil1));
        assertTrue(centralRegistry.hasDaoPermissions(address(this)));
        assertTrue(
            centralRegistry.hasElevatedPermissions(newEmergencyCouncil1)
        );
        // No longer true because we aren't using address(this) as the timelock anymore in tests
        assertFalse(centralRegistry.hasElevatedPermissions(address(this)));

        vm.expectEmit(true, true, true, true);
        emit PermissionsTransferred(
            "Emergency Council",
            newEmergencyCouncil1,
            newEmergencyCouncil2
        );

        vm.prank(newEmergencyCouncil1);
        centralRegistry.transferEmergencyCouncil(newEmergencyCouncil2);

        assertTrue(centralRegistry.hasDaoPermissions(newEmergencyCouncil2));
        assertFalse(centralRegistry.hasDaoPermissions(newEmergencyCouncil1));
        assertTrue(
            centralRegistry.hasElevatedPermissions(newEmergencyCouncil2)
        );
        assertFalse(
            centralRegistry.hasElevatedPermissions(newEmergencyCouncil1)
        );
    }
}
