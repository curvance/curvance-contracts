// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetExternalCalldataCheckerTest is TestBaseMarket {
    address public externalCalldataChecker = makeAddr("Calldata Checker");

    function test_setExternalCalldataChecker_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setExternalCalldataChecker(
            address(1),
            externalCalldataChecker
        );
    }

    function test_setExternalCalldataChecker_success() public {
        assertEq(
            centralRegistry.externalCalldataChecker(address(1)),
            address(0)
        );

        centralRegistry.setExternalCalldataChecker(
            address(1),
            externalCalldataChecker
        );

        assertEq(
            centralRegistry.externalCalldataChecker(address(1)),
            externalCalldataChecker
        );
    }
}
