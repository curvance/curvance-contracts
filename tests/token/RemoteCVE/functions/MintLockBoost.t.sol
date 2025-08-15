// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseRemoteCVE } from "../TestBaseRemoteCVE.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract MintLockBoostTest is TestBaseRemoteCVE {
    function test_mintLockBoost_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        remoteCVE.mintLockBoost(1000);
    }

    function test_mintLockBoost_success() public {
        centralRegistry.addLockingPermissions(user1);
        assertTrue(centralRegistry.hasLockingPermissions(user1));

        assertEq(remoteCVE.balanceOf(user1), 0);
        vm.prank(user1);
        remoteCVE.mintLockBoost(1000);
        assertEq(remoteCVE.balanceOf(user1), 1000);
    }
}
