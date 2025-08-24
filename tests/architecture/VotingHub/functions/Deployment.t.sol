// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { VotingHub } from "contracts/architecture/VotingHub.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseVotingHub } from "../TestBaseVotingHub.sol";

contract VotingHubDeploymentTest is TestBaseVotingHub {
    function test_votingHubDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        // No selector here since it will fail on
        // centralRegistry_.crosschainCore() call before selector error is hit.
        vm.expectRevert();
        new VotingHub(ICentralRegistry(address(1)));
    }

    function test_votingHubDeployment_success() public {
        votingHub = new VotingHub(ICentralRegistry(address(centralRegistry)));

        assertEq(
            address(votingHub.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(
            address(votingHub.gaugeManager()),
            address(centralRegistry.gaugeManager())
        );
        assertEq(votingHub.EPOCH_DURATION(), centralRegistry.EPOCH_DURATION());
    }
}
