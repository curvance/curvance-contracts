// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetFeeManagerTest is TestBaseMarket {
    event CoreContractSet(string indexed contractType, address newAddress);

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
        emit CoreContractSet("Fee Manager", newFeeManager);

        centralRegistry.setFeeManager(newFeeManager);

        assertEq(centralRegistry.feeManager(), newFeeManager);
    }
}
