// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract MintGaugeEmissionsTest is TestBaseMarketIsolated {
    function test_mintGaugeEmissions_fail_whenCallerIsNotAuthorized() public {
        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        cve.mintGaugeEmissions(address(gaugeManager), 1000);
    }

    function test_mintGaugeEmissions_success() public {
        assertEq(cve.balanceOf(address(gaugeManager)), 0);
        vm.prank(centralRegistry.messagingHub());

        cve.mintGaugeEmissions(address(gaugeManager), 1000);
        assertEq(cve.balanceOf(address(gaugeManager)), 1000);
    }
}
