// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseRemoteCVE } from "../TestBaseRemoteCVE.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract MintGaugeEmissionsTest is TestBaseRemoteCVE {
    function test_mintGaugeEmissions_fail_whenUnauthorized() public {
        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        remoteCVE.mintGaugeEmissions(address(gaugePool), 1000);
    }

    function test_mintGaugeEmissions_success() public {
        assertEq(remoteCVE.balanceOf(address(gaugePool)), 0);
        vm.prank(centralRegistry.messagingHub());

        remoteCVE.mintGaugeEmissions(address(gaugePool), 1000);
        assertEq(remoteCVE.balanceOf(address(gaugePool)), 1000);
    }
}
