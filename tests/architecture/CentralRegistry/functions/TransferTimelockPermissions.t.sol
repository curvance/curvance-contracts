// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { DAOTimelock } from "contracts/architecture/DAOTimelock.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TransferTimelockPermissionsTest is TestBaseMarketIsolated {
    event PermissionsTransferred(
        string indexed permissionsType,
        address indexed previousTimelock,
        address indexed newTimelock
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

        vm.expectEmit(true, true, true, true);
        emit PermissionsTransferred(
            "Timelock",
            address(this),
            address(newTimelock1)
        );

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

        // Before calling updateDaoAddress, check if old dao still has roles
        // and new dao doesn't have roles yet
        assertTrue(newTimelock1.hasRole(newTimelock1.PROPOSER_ROLE(), initialDaoAddress));
        assertTrue(newTimelock1.hasRole(newTimelock1.EXECUTOR_ROLE(), initialDaoAddress));
        assertFalse(newTimelock1.hasRole(newTimelock1.PROPOSER_ROLE(), address(1)));
        assertFalse(newTimelock1.hasRole(newTimelock1.EXECUTOR_ROLE(), address(1)));

        // Call updateDAOAddress explicitly
        newTimelock1.updateDaoAddress();
        
        // After updateDaoAddress, check if old dao no longer has roles
        // and new dao now has roles
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
