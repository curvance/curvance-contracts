// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetEmissionsAllocatedByEpochTest is TestBaseMarketIsolated {
    function test_setEmissionsAllocatedByEpoch_fail_whenCallerIsNotVotingHub()
        public
    {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setEmissionsAllocatedByEpoch(1, _ONE);
    }

    function test_setEmissionsAllocatedByEpoch_success() public {
        assertEq(centralRegistry.emissionsAllocatedByEpoch(1), 0);

        vm.prank(address(votingHub));
        centralRegistry.setEmissionsAllocatedByEpoch(1, _ONE);

        assertEq(centralRegistry.emissionsAllocatedByEpoch(1), _ONE);
    }
}
