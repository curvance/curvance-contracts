// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract TransferEmergencyCouncilTest is TestBaseMarket {
    address public newEmergencyCouncil1 = address(1001);
    address public newEmergencyCouncil2 = address(1002);

    event EmergencyCouncilTransferred(
        address indexed previousEmergencyCouncil,
        address indexed newEmergencyCouncil
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
        emit EmergencyCouncilTransferred(address(this), newEmergencyCouncil1);

        centralRegistry.transferEmergencyCouncil(newEmergencyCouncil1);

        assertTrue(centralRegistry.hasDaoPermissions(newEmergencyCouncil1));
        assertTrue(centralRegistry.hasDaoPermissions(address(this)));
        assertTrue(
            centralRegistry.hasElevatedPermissions(newEmergencyCouncil1)
        );
        assertTrue(centralRegistry.hasElevatedPermissions(address(this)));

        vm.expectEmit(true, true, true, true);
        emit EmergencyCouncilTransferred(
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
