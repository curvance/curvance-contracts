// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseChildCVE } from "../TestBaseChildCVE.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract MintLockBoostTest is TestBaseChildCVE {
    function test_mintLockBoost_fail_whenUnauthorized() public {
        vm.prank(address(0));

        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        childCVE.mintLockBoost(1000);
    }

    function test_mintLockBoost_success() public {
        centralRegistry.addLockingPermissions(user1);
        assertTrue(centralRegistry.hasLockingPermissions(user1));

        assertEq(childCVE.balanceOf(user1), 0);
        vm.prank(user1);
        childCVE.mintLockBoost(1000);
        assertEq(childCVE.balanceOf(user1), 1000);
    }
}
