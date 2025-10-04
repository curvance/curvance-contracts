// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { DAOTimelock } from "contracts/architecture/DAOTimelock.sol";

import { console2 } from "forge-std/console2.sol";

contract TransferEmergencyCouncilTest is TestBaseMarketIsolated {
    address public newCouncil1 = address(1001);
    address public newCouncil2 = address(1002);
    address public newDao = address(1003);

    event PermissionsTransferred(
        string indexed permissionsType,
        address previousEmergencyCouncil,
        address newEmergencyCouncil
    );

    // From DAOTimelock
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);

    function test_transferEmergencyCouncil_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.transferEmergencyCouncil(newCouncil1);
    }

    function test_transferEmergencyCouncil_success_whenEmergencyCouncilIsAlsoDao() public {
        assertTrue(centralRegistry.hasDaoPermissions(address(this)));
        assertTrue(centralRegistry.hasElevatedPermissions(address(this)));

        vm.expectEmit(true, true, true, true);
        emit PermissionsTransferred(
            "Emergency Council",
            address(this),
            newCouncil1
        );

        console2.log("timelock address: ", centralRegistry.timelock());
        console2.log("emergency council: ", centralRegistry.emergencyCouncil());
        console2.log("dao address:", centralRegistry.daoAddress());

        centralRegistry.transferEmergencyCouncil(newCouncil1);

        assertTrue(centralRegistry.hasDaoPermissions(newCouncil1));
        assertTrue(centralRegistry.hasDaoPermissions(address(this)));

        assertTrue(centralRegistry.hasMarketPermissions(newCouncil1));
        assertTrue(centralRegistry.hasElevatedPermissions(newCouncil1));
        
        // Previous emergency council retains DAO because it's also the DAO,
        // but loses elevated and market permissions since it's not also the timelock.
        assertFalse(centralRegistry.hasMarketPermissions(address(this)));
        assertFalse(centralRegistry.hasElevatedPermissions(address(this)));

        vm.expectEmit(true, true, true, true);
        emit PermissionsTransferred(
            "Emergency Council",
            newCouncil1,
            newCouncil2
        );

        console2.log("timelock address 2: ", centralRegistry.timelock());
        console2.log("emergency council 2: ", centralRegistry.emergencyCouncil());
        console2.log("dao address 2:", centralRegistry.daoAddress());

        vm.prank(newCouncil1);
        centralRegistry.transferEmergencyCouncil(newCouncil2);

        assertTrue(centralRegistry.hasDaoPermissions(newCouncil2));
        assertTrue(centralRegistry.hasMarketPermissions(newCouncil2));
        assertTrue(centralRegistry.hasElevatedPermissions(newCouncil2));

        assertFalse(centralRegistry.hasDaoPermissions(newCouncil1));
        assertFalse(centralRegistry.hasMarketPermissions(newCouncil1));
        assertFalse(centralRegistry.hasElevatedPermissions(newCouncil1));
    }

    function test_transferEmergencyCouncil_success_whenEmergencyCouncilIsNotDao() public {
        // First transfer DAO permissions to a different address
        centralRegistry.transferDaoPermissions(newDao);
        
        assertTrue(centralRegistry.hasDaoPermissions(newDao));
        assertTrue(centralRegistry.hasDaoPermissions(address(this))); // Still has DAO permissions as emergency council
        assertTrue(centralRegistry.hasElevatedPermissions(address(this)));
        assertTrue(centralRegistry.hasMarketPermissions(address(this)));

        vm.expectEmit(true, true, true, true);
        emit PermissionsTransferred(
            "Emergency Council",
            address(this),
            newCouncil1
        );

        centralRegistry.transferEmergencyCouncil(newCouncil1);

        assertTrue(centralRegistry.hasDaoPermissions(newCouncil1));
        assertTrue(centralRegistry.hasMarketPermissions(newCouncil1));
        assertTrue(centralRegistry.hasElevatedPermissions(newCouncil1));

        // Previous emergency council loses permissions since it's not the dao
        assertFalse(centralRegistry.hasDaoPermissions(address(this)));
        assertFalse(centralRegistry.hasMarketPermissions(address(this)));
        assertFalse(centralRegistry.hasElevatedPermissions(address(this)));

        // dao address retains its permissions
        assertTrue(centralRegistry.hasDaoPermissions(newDao));
    }

    // Tests that updateRoles is called inside of transferEmergencyCouncil when timelock != address(0)
    function test_transferEmergencyCouncil_success_updatesTimelockRoles() public {
        address timelockAddress = centralRegistry.timelock();
        assertTrue(timelockAddress != address(0));

        bytes32 CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
        vm.expectEmit(false, true, true, false, timelockAddress);
        emit RoleGranted(CANCELLER_ROLE, newCouncil1, address(centralRegistry));

        centralRegistry.transferEmergencyCouncil(newCouncil1);

        // Assert DAO retains its canceller role on the timelock
        assertTrue(
            DAOTimelock(payable(timelockAddress)).hasRole(
                CANCELLER_ROLE,
                centralRegistry.daoAddress()
            )
        );
    }
}
