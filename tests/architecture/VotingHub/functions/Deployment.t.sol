// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseVotingHub } from "../TestBaseVotingHub.sol";
import { VotingHub } from "contracts/architecture/VotingHub.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract VotingHubDeploymentTest is TestBaseVotingHub {
    function test_votingHubDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert();
        new VotingHub(ICentralRegistry(address(1)), _ONE);
    }

    function test_votingHubDeployment_success() public {
        votingHub = new VotingHub(
            ICentralRegistry(address(centralRegistry)),
            _ONE
        );

        assertEq(
            address(votingHub.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(address(votingHub.cve()), address(cve));
        assertEq(address(votingHub.veCVE()), address(veCVE));

        uint256 numEras = votingHub.PROTOCOL_REWARD_ERAS();

        for (uint256 i; i < numEras; i++) {
            assertEq(
                votingHub.targetEmissionAllocationByEra(i),
                _ONE / (2 ** i)
            );
        }
    }
}
