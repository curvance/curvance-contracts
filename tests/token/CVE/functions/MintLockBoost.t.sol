// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract MintLockBoostTest is TestBaseMarketIsolated {
    function test_mintLockBoost_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        cve.mintLockBoost(1000);
    }

    function test_mintLockBoost_success() public {
        centralRegistry.addLockingPermissions(user1);
        assertTrue(centralRegistry.hasLockingPermissions(user1));

        assertEq(cve.balanceOf(user1), 0);
        vm.prank(user1);
        cve.mintLockBoost(1000);
        assertEq(cve.balanceOf(user1), 1000);
    }
}
