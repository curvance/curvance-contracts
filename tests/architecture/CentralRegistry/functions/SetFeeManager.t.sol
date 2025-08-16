// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetFeeManagerTest is TestBaseMarketIsolated {
    event CoreContractUpdated(string indexed contractType, address newAddress);

    address public newFeeManager = makeAddr("Fee Manager");

    function test_setFeeManager_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setFeeManager(newFeeManager);
    }

    function test_setFeeManager_success() public {
        assertEq(centralRegistry.feeManager(), address(feeManager));

        vm.expectEmit(true, true, true, true);
        emit CoreContractUpdated("Fee Manager", newFeeManager);

        centralRegistry.setFeeManager(newFeeManager);

        assertEq(centralRegistry.feeManager(), newFeeManager);
    }
}
