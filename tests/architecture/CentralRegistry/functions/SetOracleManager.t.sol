// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetOracleManagerTest is TestBaseMarketIsolated {
    event CoreContractUpdated(string indexed contractType, address newAddress);

    address public newOracleManager = makeAddr("Oracle Manager");

    function test_setOracleManager_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setOracleManager(newOracleManager);
    }

    function test_setOracleManager_success() public {
        assertEq(centralRegistry.oracleManager(), address(oracleManager));

        vm.expectEmit(true, true, true, true);
        emit CoreContractUpdated("Oracle Manager", newOracleManager);

        centralRegistry.setOracleManager(newOracleManager);

        assertEq(centralRegistry.oracleManager(), newOracleManager);
    }
}
