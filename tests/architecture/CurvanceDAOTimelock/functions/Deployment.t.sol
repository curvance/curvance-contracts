// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { DAOTimelock } from "contracts/architecture/DAOTimelock.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseTimelock } from "../TestBaseTimelock.sol";

contract TimelockDeploymentTest is TestBaseTimelock {
    function test_timelockDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry
                .selector
        );
        new DAOTimelock(ICentralRegistry(address(0)));
    }

    function test_timelockDeployment_success() public {
        DAOTimelock timelock = new DAOTimelock(
            ICentralRegistry(address(centralRegistry))
        );

        assertEq(
            address(timelock.centralRegistry()),
            address(centralRegistry)
        );
        assertTrue(
            timelock.hasRole(
                timelock.PROPOSER_ROLE(),
                centralRegistry.daoAddress()
            )
        );
        assertTrue(
            timelock.hasRole(
                timelock.EXECUTOR_ROLE(),
                centralRegistry.daoAddress()
            )
        );
    }
}
