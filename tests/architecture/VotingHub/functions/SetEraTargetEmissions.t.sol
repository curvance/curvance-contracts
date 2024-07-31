// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseVotingHub } from "../TestBaseVotingHub.sol";
import { VotingHub } from "contracts/architecture/VotingHub.sol";

contract SetEraTargetEmissionsTest is TestBaseVotingHub {
    function test_setEraTargetEmissions_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(user1);

        vm.expectRevert(VotingHub.VotingHub__Unauthorized.selector);
        votingHub.setEraTargetEmissions(_ONE * 2);
    }

    function test_setEraTargetEmissions_success() public {
        uint256 numEras = votingHub.PROTOCOL_REWARD_ERAS();

        for (uint256 i; i < numEras; i++) {
            assertEq(
                votingHub.targetEmissionAllocationByEra(i),
                _ONE / (2 ** i)
            );
        }

        votingHub.setEraTargetEmissions(_ONE * 2);

        for (uint256 i; i < numEras; i++) {
            assertEq(
                votingHub.targetEmissionAllocationByEra(i),
                (_ONE * 2) / (2 ** i)
            );
        }
    }
}
