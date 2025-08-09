// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { VeCVE } from "contracts/token/VeCVE.sol";
import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";

contract UpdateUserPointsTest is TestBaseVeCVE {
    function setUp() public override {
        super.setUp();

        _skipRestrictionDuration();
    }

    function test_updateUserPoints_fail_unauthorized() public {
        vm.prank(address(1));

        vm.expectRevert(VeCVE.VeCVE__Unauthorized.selector);
        veCVE.updateUserPoints(address(1), 100);
    }

    function test_updateUserPoints_success() public {
        _prepareCVE(address(this), 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(100e18, false, action, "", 0);
        assertEq(veCVE.userPoints(address(this)), 100e18);

        vm.startPrank(address(rewardManager));
        // invalid epoch won't change user points
        veCVE.updateUserPoints(address(this), 10);
        assertEq(veCVE.userPoints(address(this)), 100e18);

        veCVE.updateUserPoints(address(this), veCVE.freshLockEpoch());
        assertEq(veCVE.userPoints(address(this)), 0);

        vm.stopPrank();
    }
}
