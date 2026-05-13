// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetMulticallCheckerTest is TestBaseMarketIsolated {
    address public multicallChecker = makeAddr("Multicall Checker");

    function test_setMulticallChecker_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setMulticallChecker(address(1), multicallChecker);
    }

    function test_setMulticallChecker_success() public {
        assertEq(centralRegistry.multicallChecker(address(1)), address(0));

        centralRegistry.setMulticallChecker(address(1), multicallChecker);

        assertEq(centralRegistry.multicallChecker(address(1)), multicallChecker);
    }
}
