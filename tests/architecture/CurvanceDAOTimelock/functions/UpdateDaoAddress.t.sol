// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseTimelock } from "../TestBaseTimelock.sol";
import { DAOTimelock } from "contracts/architecture/DAOTimelock.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract UpdateRolesTest is TestBaseTimelock {
    function test_updateRoles_success() public {
        DAOTimelock timelock = new DAOTimelock(
            ICentralRegistry(address(centralRegistry))
        );

        address daoAddress = centralRegistry.daoAddress();

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), daoAddress));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), daoAddress));

        timelock.updateRoles();

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), daoAddress));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), daoAddress));

        vm.prank(daoAddress);
        centralRegistry.transferDaoPermissions(address(1));

        timelock.updateRoles();

        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), daoAddress));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), daoAddress));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(1)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(1)));
    }
}
