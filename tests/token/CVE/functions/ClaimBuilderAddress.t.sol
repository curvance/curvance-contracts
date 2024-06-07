// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract ClaimBuilderAddressTest is TestBaseMarket {
    function test_claimBuilderAddress_fail_whenUnauthorized() public {
        vm.startPrank(address(1));
        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        cve.claimBuilderAddress();
        vm.stopPrank();
    }

    function test_claimBuilderAddress_success() public {
        address builderAddress = cve.builderAddress();

        assertNotEq(builderAddress, address(1));

        vm.prank(builderAddress);
        cve.setPendingBuilderAddress(address(1));

        vm.prank(address(1));
        cve.claimBuilderAddress();

        assertEq(cve.builderAddress(), address(1));
    }
}
