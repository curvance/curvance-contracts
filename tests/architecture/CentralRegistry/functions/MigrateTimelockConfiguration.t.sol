// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { Timelock } from "contracts/architecture/CurvanceDAOTimelock.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ITimelock } from "contracts/interfaces/ITimelock.sol";

contract MigrateTimelockConfigurationTest is TestBaseMarket {
    event NewTimelockConfiguration(
        address indexed previousTimelock,
        address indexed newTimelock
    );

    function test_migrateTimelockConfiguration_fail_whenUnauthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.migrateTimelockConfiguration(address(1));
    }

    function test_migrateTimelockConfiguration_success() public {
        Timelock newTimelock = new Timelock(
            ICentralRegistry(address(centralRegistry))
        );

        assertTrue(centralRegistry.hasDaoPermissions(address(this)));
        assertTrue(centralRegistry.hasElevatedPermissions(address(this)));

        vm.expectEmit(true, true, true, true);
        emit NewTimelockConfiguration(address(this), address(newTimelock));

        centralRegistry.migrateTimelockConfiguration(address(newTimelock));

        assertTrue(centralRegistry.hasDaoPermissions(address(newTimelock)));
        assertFalse(centralRegistry.hasDaoPermissions(address(this)));
        assertTrue(
            centralRegistry.hasElevatedPermissions(address(newTimelock))
        );
        assertFalse(centralRegistry.hasElevatedPermissions(address(this)));

        vm.prank(address(newTimelock));
        centralRegistry.transferDaoOwnership(address(1));

        assertTrue(
            newTimelock.hasRole(newTimelock.PROPOSER_ROLE(), address(1))
        );
        assertTrue(
            newTimelock.hasRole(newTimelock.EXECUTOR_ROLE(), address(1))
        );
    }
}
