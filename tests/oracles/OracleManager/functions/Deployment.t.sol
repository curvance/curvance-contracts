// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract OracleManagerDeploymentTest is TestBaseOracleManager {
    function test_oracleManagerDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        new OracleManager(ICentralRegistry(address(1)));
    }

    function test_oracleManagerDeployment_success() public {
        oracleManager = new OracleManager(
            ICentralRegistry(address(centralRegistry))
        );

        assertEq(
            address(oracleManager.centralRegistry()),
            address(centralRegistry)
        );
    }
}
