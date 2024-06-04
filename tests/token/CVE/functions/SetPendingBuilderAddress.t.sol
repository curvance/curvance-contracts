// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract SetPendingBuilderAddressTest is TestBaseMarket {
    function test_setPendingBuilderAddress_fail_whenUnauthorized() public {
        vm.startPrank(address(0));
        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        cve.setPendingBuilderAddress(user1);
        vm.stopPrank();
    }

    function test_setPendingBuilderAddress_success() public {
        address builderAddress = cve.builderAddress();

        vm.prank(builderAddress);
        cve.setPendingBuilderAddress(address(1));

        assertEq(cve.pendingBuilderAddress(), address(1));
    }
}
