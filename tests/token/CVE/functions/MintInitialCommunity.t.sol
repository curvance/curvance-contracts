// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CVE } from "contracts/token/CVE.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract MintCommunityAllocationTest is TestBaseMarketIsolated {
    function test_mintCommunityAllocation_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));
        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        cve.mintCommunityAllocation(1000);
    }

    function test_mintCommunityAllocation_fail_whenInsufficientCVEAllocation()
        public
    {
        assertEq(cve.initialCommunityMinted(), 0);
        uint256 invalidAmount = cve.initialCommunityAllocation() + 1;

        vm.expectRevert(CVE.CVE__InsufficientCVEAllocation.selector);
        cve.mintCommunityAllocation(invalidAmount);
    }

    function test_mintCommunityAllocation_success() public {
        assertEq(cve.initialCommunityMinted(), 0);
        uint256 validAmount = cve.initialCommunityAllocation();
        uint256 prevBalance = cve.balanceOf(address(this));
        cve.mintCommunityAllocation(validAmount);

        assertEq(cve.initialCommunityMinted(), validAmount);
        assertEq(cve.balanceOf(address(this)), prevBalance + validAmount);
    }
}
