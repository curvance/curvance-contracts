// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseTimelock } from "../TestBaseTimelock.sol";
import { DAOTimelock } from "contracts/architecture/DAOTimelock.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

// Tests that cover TRST-M-14 fixes.

// Scenario 1: old DAO is Emergency Council.
// When DAO changes, Emergency Council should retain CANCELLER_ROLE.

// Scenario 2: old emergency council is DAO.
// When Emergency Council changes, DAO should retain CANCELLER_ROLE.

contract UpdateRolesOverlapTest is TestBaseTimelock {

    // When old DAO is the emergency council
    function test_updateRoles_preservesCanceller_onDaoChange() public {
        DAOTimelock timelock = new DAOTimelock(ICentralRegistry(address(centralRegistry)));

        // Establish overlap scenario where DAO = emergencyCouncil.
        address emergencyCouncil_ = centralRegistry.emergencyCouncil();
        centralRegistry.transferDaoPermissions(emergencyCouncil_);
        timelock.updateRoles();

        // Change DAO to a new address
        address newDao = makeAddr("newDao");
        centralRegistry.transferDaoPermissions(newDao);
        timelock.updateRoles();

        // New DAO gains proposer, executor, and canceller roles.
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), newDao));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), newDao));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), newDao));

        // EC retains canceller role. (Included fix for issue TRST-M-14).
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), emergencyCouncil_));

        // Old DAO (which = emergencyCouncil) loses proposer and executor roles.
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), emergencyCouncil_));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), emergencyCouncil_));
    }

    // When the old emergency council is the DAO
    function test_updateRoles_preservesCanceller_onEmergencyCouncilChange() public {
        DAOTimelock timelock = new DAOTimelock(ICentralRegistry(address(centralRegistry)));

        // Establish overlap scenario where DAO = emergencyCouncil.
        address emergencyCouncil_initial = centralRegistry.emergencyCouncil();
        centralRegistry.transferDaoPermissions(emergencyCouncil_initial);
        timelock.updateRoles();

        // Change emergencyCouncil to another address
        address newEmergencyCouncil = makeAddr("newEmergencyCouncil");
        centralRegistry.transferEmergencyCouncil(newEmergencyCouncil);
        timelock.updateRoles();

        // DAO (also old emergencyCouncil) retains canceller role (Included fix for TRST-M-14)
        address currentDao = centralRegistry.daoAddress(); // still emergencyCouncil_initial
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), currentDao));

        // New emergencyCouncil gains canceller
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), newEmergencyCouncil));

        // DAO still proposer and executor
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), currentDao));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), currentDao));
    }
}