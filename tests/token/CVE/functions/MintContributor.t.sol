// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract MintContributorTest is TestBaseMarket {
    function test_mintContributor_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));
        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        cve.mintContributor();
    }

    function test_mintContributor_fail_whenCVEParametersAreInvalid() public {
        address contributorAddress = cve.contributorAddress();
        vm.prank(contributorAddress);
        vm.expectRevert(CVEBase.CVE__ParametersAreInvalid.selector);
        cve.mintContributor();
    }

    function test_mintContributor_success() public {
        assertEq(cve.contributorAllocationMinted(), 0);

        skip(62 days);
        address contributorAddress = cve.contributorAddress();
        uint256 prevBalance = cve.balanceOf(contributorAddress);
        vm.prank(contributorAddress);
        cve.mintContributor();

        // 2 months worth of contributor allocation
        uint256 expectedAmount = 2 * cve.contributorAllocationPerMonth();
        assertEq(expectedAmount, cve.contributorAllocationMinted());
        assertEq(
            cve.balanceOf(contributorAddress),
            prevBalance + expectedAmount
        );

        skip(31 days);
        vm.prank(contributorAddress);
        cve.mintContributor();

        // 3 months worth of contributor allocation
        expectedAmount = cve.contributorAllocationPerMonth() * 3;
        assertEq(expectedAmount, cve.contributorAllocationMinted());
        assertEq(
            cve.balanceOf(contributorAddress),
            prevBalance + expectedAmount
        );

        // 4 years
        skip(1460 days);
        vm.prank(contributorAddress);
        cve.mintContributor();

        expectedAmount = cve.contributorAllocation();
        assertEq(expectedAmount, cve.contributorAllocationMinted());
        assertEq(
            cve.balanceOf(contributorAddress),
            prevBalance + expectedAmount
        );
    }
}
