// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { Timelock } from "contracts/architecture/CurvanceDAOTimelock.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract MigrateTimelockConfigurationTest is TestBaseMarket {
    event NewTimelockConfiguration(
        address indexed previousTimelock,
        address indexed newTimelock
    );

    function test_migrateTimelockConfiguration_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.migrateTimelockConfiguration(address(1));
    }

    function test_migrateTimelockConfiguration_success() public {
        Timelock newTimelock1 = new Timelock(
            ICentralRegistry(address(centralRegistry))
        );

        assertTrue(centralRegistry.hasDaoPermissions(address(this)));
        assertTrue(centralRegistry.hasElevatedPermissions(address(this)));

        vm.expectEmit(true, true, true, true);
        emit NewTimelockConfiguration(address(this), address(newTimelock1));

        centralRegistry.migrateTimelockConfiguration(address(newTimelock1));

        assertTrue(centralRegistry.hasDaoPermissions(address(newTimelock1)));
        assertTrue(centralRegistry.hasDaoPermissions(address(this)));
        assertTrue(
            centralRegistry.hasElevatedPermissions(address(newTimelock1))
        );
        assertTrue(centralRegistry.hasElevatedPermissions(address(this)));

        vm.prank(address(newTimelock1));
        centralRegistry.transferDaoOwnership(address(1));

        assertTrue(
            newTimelock1.hasRole(newTimelock1.PROPOSER_ROLE(), address(1))
        );
        assertTrue(
            newTimelock1.hasRole(newTimelock1.EXECUTOR_ROLE(), address(1))
        );

        Timelock newTimelock2 = new Timelock(
            ICentralRegistry(address(centralRegistry))
        );

        assertTrue(centralRegistry.hasDaoPermissions(address(newTimelock1)));
        assertTrue(
            centralRegistry.hasElevatedPermissions(address(newTimelock1))
        );

        vm.expectEmit(true, true, true, true);
        emit NewTimelockConfiguration(
            address(newTimelock1),
            address(newTimelock2)
        );

        centralRegistry.migrateTimelockConfiguration(address(newTimelock2));

        assertTrue(centralRegistry.hasDaoPermissions(address(newTimelock2)));
        assertFalse(centralRegistry.hasDaoPermissions(address(newTimelock1)));
        assertTrue(
            centralRegistry.hasElevatedPermissions(address(newTimelock2))
        );
        assertFalse(
            centralRegistry.hasElevatedPermissions(address(newTimelock1))
        );

        vm.prank(address(newTimelock2));
        centralRegistry.transferDaoOwnership(address(2));

        assertTrue(
            newTimelock2.hasRole(newTimelock2.PROPOSER_ROLE(), address(2))
        );
        assertTrue(
            newTimelock2.hasRole(newTimelock2.EXECUTOR_ROLE(), address(2))
        );
    }
}
