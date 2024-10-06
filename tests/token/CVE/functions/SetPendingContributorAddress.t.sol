// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract SetPendingContributorAddressTest is TestBaseMarket {
    function test_setPendingContributorAddress_fail_whenUnauthorized() public {
        vm.prank(address(0));

        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        cve.setPendingContributorAddress(user1);
    }

    function test_setPendingContributorAddress_success() public {
        address contributorAddress = cve.contributorAddress();

        vm.prank(contributorAddress);
        cve.setPendingContributorAddress(address(1));

        assertEq(cve.pendingContributorAddress(), address(1));
    }
}
