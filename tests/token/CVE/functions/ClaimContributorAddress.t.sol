// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract ClaimContributorAddressTest is TestBaseMarketIsolated {
    function test_claimContributorAddress_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        cve.claimContributorAddress();
    }

    function test_claimContributorAddress_success() public {
        address contributorAddress = cve.contributorAddress();

        assertNotEq(contributorAddress, address(1));

        vm.prank(contributorAddress);
        cve.setPendingContributorAddress(address(1));

        vm.prank(address(1));
        cve.claimContributorAddress();

        assertEq(cve.contributorAddress(), address(1));
    }
}
