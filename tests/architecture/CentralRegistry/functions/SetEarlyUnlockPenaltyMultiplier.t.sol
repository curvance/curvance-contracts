// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetEarlyUnlockPenaltyMultiplierTest is TestBaseMarketIsolated {
    function test_setEarlyUnlockPenaltyMultiplier_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setEarlyUnlockPenaltyMultiplier(100);
    }

    function test_setEarlyUnlockPenaltyMultiplier_fail_whenParametersMisconfigured()
        public
    {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.setEarlyUnlockPenaltyMultiplier(9001);

        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.setEarlyUnlockPenaltyMultiplier(2999);

        centralRegistry.setEarlyUnlockPenaltyMultiplier(0);
        centralRegistry.setEarlyUnlockPenaltyMultiplier(9000);
        centralRegistry.setEarlyUnlockPenaltyMultiplier(3000);
    }

    function test_setEarlyUnlockPenaltyMultiplier_success() public {
        centralRegistry.setEarlyUnlockPenaltyMultiplier(3000);
        assertEq(centralRegistry.earlyUnlockPenaltyMultiplier(), 3000);
    }
}
