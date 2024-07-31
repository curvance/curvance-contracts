// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseVotingHub } from "../TestBaseVotingHub.sol";
import { VotingHub } from "contracts/architecture/VotingHub.sol";

contract StartTest is TestBaseVotingHub {
    function test_start_fail_whenCallerIsNotAuthorized() public {
        vm.prank(user1);

        vm.expectRevert(VotingHub.VotingHub__Unauthorized.selector);
        votingHub.start();
    }

    function test_start_fail_whenAlreadyStarted() public {
        votingHub.start();

        vm.expectRevert(VotingHub.VotingHub__HubStarted.selector);
        votingHub.start();
    }

    function test_start_success() public {
        votingHub.start();

        assertEq(votingHub.startTime(), veCVE.nextEpochStartTime());
    }
}
