// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";

contract DisabledTransfers is TestBaseVeCVE {
    function setUp() public override {
        super.setUp();

        _prepareCVE(address(this), 100e18);
        cve.approve(address(veCVE), 100e18);

        _skipRestrictionDuration();

        veCVE.createLock(30e18, false, action, "", 0);
    }

    function test_tranfer_fail() public {
        assertGt(veCVE.balanceOf(address(this)), 0);
        vm.expectRevert(VeCVE.VeCVE__NonTransferrable.selector);
        veCVE.transfer(address(this), 1e18);
    }

    function test_transferFrom_fail() public {
        assertGt(veCVE.balanceOf(address(this)), 0);
        vm.expectRevert(VeCVE.VeCVE__NonTransferrable.selector);
        veCVE.transferFrom(address(this), address(this), 1e18);
    }
}
