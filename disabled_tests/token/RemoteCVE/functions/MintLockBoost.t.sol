// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseRemoteCVE } from "../TestBaseRemoteCVE.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract MintLockBoostTest is TestBaseRemoteCVE {
    function test_mintLockBoost_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        remoteCVE.mintLockBoost(1000);
    }

    function test_mintLockBoost_success() public {
        address gaugeManager = centralRegistry.gaugeManager();

        assertEq(remoteCVE.balanceOf(gaugeManager), 0);
        vm.prank(gaugeManager);
        remoteCVE.mintLockBoost(1000);
        assertEq(remoteCVE.balanceOf(gaugeManager), 1000);
    }
}
