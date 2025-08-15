// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { DAOTimelock } from "contracts/architecture/DAOTimelock.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TransferTimelockPermissionsTest is TestBaseMarketIsolated {
    event PermissionsTransferred(
        string indexed permissionsType,
        address previousAddress,
        address newAddress
    );

    event PermissionsUpdated(
        string indexed permissionsType,
        address addressUpdated,
        bool isAdded
    );

    function test_transferTimelockPermissions_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.transferTimelockPermissions(address(1));
    }

    function test_transferTimelockPermissions_success() public {
        DAOTimelock newTimelock1 = new DAOTimelock(
            ICentralRegistry(address(centralRegistry))
        );

        assertTrue(centralRegistry.hasDaoPermissions(address(this)));
        assertTrue(centralRegistry.hasElevatedPermissions(address(this)));

        // Expect the PermissionsUpdated event for Market permission removal first
        vm.expectEmit(true, true, true, true);
        emit PermissionsUpdated("Market", address(daoTimelock), false);
        
        // Then expect the main PermissionsTransferred event
        vm.expectEmit(true, true, true, true);
        emit PermissionsTransferred(
            "Timelock",
            address(daoTimelock),
            address(newTimelock1)
        );
        
        // Then expect the PermissionsUpdated event for Market permission addition
        vm.expectEmit(true, true, true, true);
        emit PermissionsUpdated("Market", address(newTimelock1), true);

        centralRegistry.transferTimelockPermissions(address(newTimelock1));

        assertTrue(centralRegistry.hasDaoPermissions(address(newTimelock1)));
        assertTrue(centralRegistry.hasDaoPermissions(address(this)));
        assertTrue(
            centralRegistry.hasElevatedPermissions(address(newTimelock1))
        );
        assertTrue(centralRegistry.hasElevatedPermissions(address(this)));

        // Get initial dao address for comparison
        address initialDaoAddress = centralRegistry.daoAddress();

        // Transfer dao permissions
        vm.prank(address(newTimelock1));
        centralRegistry.transferDaoPermissions(address(1));

        // After transferDaoPermissions (which now calls updateRoles automatically),
        // check if old dao no longer has roles and new dao now has roles
        assertFalse(newTimelock1.hasRole(newTimelock1.PROPOSER_ROLE(), initialDaoAddress));
        assertFalse(newTimelock1.hasRole(newTimelock1.EXECUTOR_ROLE(), initialDaoAddress));
        assertTrue(newTimelock1.hasRole(newTimelock1.PROPOSER_ROLE(), address(1)));
        assertTrue(newTimelock1.hasRole(newTimelock1.EXECUTOR_ROLE(), address(1)));

        DAOTimelock newTimelock2 = new DAOTimelock(
            ICentralRegistry(address(centralRegistry))
        );

        assertTrue(centralRegistry.hasDaoPermissions(address(newTimelock1)));
        assertTrue(
            centralRegistry.hasElevatedPermissions(address(newTimelock1))
        );

        vm.expectEmit(true, true, true, true);
        emit PermissionsTransferred(
            "Timelock",
            address(newTimelock1),
            address(newTimelock2)
        );

        centralRegistry.transferTimelockPermissions(address(newTimelock2));

        assertTrue(centralRegistry.hasDaoPermissions(address(newTimelock2)));
        assertFalse(centralRegistry.hasDaoPermissions(address(newTimelock1)));
        assertTrue(
            centralRegistry.hasElevatedPermissions(address(newTimelock2))
        );
        assertFalse(
            centralRegistry.hasElevatedPermissions(address(newTimelock1))
        );

        vm.prank(address(newTimelock2));
        centralRegistry.transferDaoPermissions(address(2));

        assertTrue(
            newTimelock2.hasRole(newTimelock2.PROPOSER_ROLE(), address(2))
        );
        assertTrue(
            newTimelock2.hasRole(newTimelock2.EXECUTOR_ROLE(), address(2))
        );
    }
}
