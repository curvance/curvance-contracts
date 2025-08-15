// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetEraTargetEmissionsTest is TestBaseMarketIsolated {
    function test_setEraTargetEmissions_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(user1);

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setEraTargetEmissions(_ONE * 2);
    }

    function test_setEraTargetEmissions_success() public {
        uint256 numEras = votingHub.protocolRewardEras();

        for (uint256 i; i < numEras; i++) {
            assertEq(
                centralRegistry.targetEmissionAllocationByEra(i),
                _ONE / (2 ** i)
            );
        }

        centralRegistry.setEraTargetEmissions(_ONE * 2);

        for (uint256 i; i < numEras; i++) {
            assertEq(
                centralRegistry.targetEmissionAllocationByEra(i),
                (_ONE * 2) / (2 ** i)
            );
        }
    }
}
