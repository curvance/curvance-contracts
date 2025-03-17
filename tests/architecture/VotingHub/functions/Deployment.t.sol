// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseVotingHub } from "../TestBaseVotingHub.sol";
import { VotingHub } from "contracts/architecture/VotingHub.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract VotingHubDeploymentTest is TestBaseVotingHub {
    function test_votingHubDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
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
        assertEq(votingHub.epochDuration(), centralRegistry.EPOCH_DURATION());
    }
}
