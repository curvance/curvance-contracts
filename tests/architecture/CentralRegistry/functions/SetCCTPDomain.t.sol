// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetDomainTest is TestBaseMarketIsolated {
    event DomainSet(uint32 newDomain);

    function test_setDomain_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setDomain(3);
    }

    function test_setDomain_success() public {
        assertEq(centralRegistry.domain(), 0);

        vm.expectEmit(true, true, true, true);
        emit DomainSet(3);

        centralRegistry.setDomain(3);

        assertEq(centralRegistry.domain(), 3);
    }
}
