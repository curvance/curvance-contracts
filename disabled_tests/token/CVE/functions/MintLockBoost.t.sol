// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract MintLockBoostTest is TestBaseMarketIsolated {
    function test_mintLockBoost_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        cve.mintLockBoost(1000);
    }

    function test_mintLockBoost_success() public {
        address gaugeManager = centralRegistry.gaugeManager();

        assertEq(cve.balanceOf(gaugeManager), 0);
        vm.prank(gaugeManager);
        cve.mintLockBoost(1000);
        assertEq(cve.balanceOf(gaugeManager), 1000);
    }
}
