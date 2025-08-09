// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { BASIS_POINTS } from "contracts/libraries/ConstantsLib.sol";

contract SetVoteBoostMultiplierTest is TestBaseMarketIsolated {
    function test_setVoteBoostMultiplier_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setVoteBoostMultiplier(100);
    }

    function test_setVoteBoostMultiplier_fail_whenParametersMisconfigured()
        public
    {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.setVoteBoostMultiplier(BASIS_POINTS);

        centralRegistry.setVoteBoostMultiplier(0);
        centralRegistry.setVoteBoostMultiplier(BASIS_POINTS + 1);
    }

    function test_setVoteBoostMultiplier_success() public {
        centralRegistry.setVoteBoostMultiplier(11000);
        assertEq(centralRegistry.voteBoostMultiplier(), 11000);
    }
}
