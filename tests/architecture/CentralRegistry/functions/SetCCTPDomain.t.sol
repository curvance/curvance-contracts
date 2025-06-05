// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetCCTPDomainTest is TestBaseMarketIsolated {
    event CCTPDomainSet(uint32 newDomain);

    function test_setCCTPDomain_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setCCTPDomain(3);
    }

    function test_setCCTPDomain_success() public {
        assertEq(centralRegistry.cctpDomain(), 0);

        vm.expectEmit(true, true, true, true);
        emit CCTPDomainSet(3);

        centralRegistry.setCCTPDomain(3);

        assertEq(centralRegistry.cctpDomain(), 3);
    }
}
