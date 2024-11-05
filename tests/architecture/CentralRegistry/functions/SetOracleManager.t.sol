// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetOracleManagerTest is TestBaseMarket {
    event CoreContractSet(string indexed contractType, address newAddress);

    address public newOracleManager = makeAddr("Oracle Manager");

    function test_setOracleManager_fail_whenUnauthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setOracleManager(newOracleManager);
    }

    function test_setOracleManager_success() public {
        assertEq(centralRegistry.oracleManager(), address(oracleManager));

        vm.expectEmit(true, true, true, true);
        emit CoreContractSet("Oracle Manager", newOracleManager);

        centralRegistry.setOracleManager(newOracleManager);

        assertEq(centralRegistry.oracleManager(), newOracleManager);
    }
}
