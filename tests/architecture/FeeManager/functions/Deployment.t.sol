// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseFeeManager } from "../TestBaseFeeManager.sol";
import { FeeManager } from "contracts/architecture/FeeManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract FeeManagerDeploymentTest is TestBaseFeeManager {
    function test_feeManagerDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            FeeManager.FeeManager__InvalidCentralRegistry.selector
        );
        new FeeManager(ICentralRegistry(address(0)));
    }

    function test_feeManagerDeployment_success() public {
        feeManager = new FeeManager(
            ICentralRegistry(address(centralRegistry))
        );

        assertEq(
            address(feeManager.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(
            address(feeManager.getOracleManager()),
            centralRegistry.oracleManager()
        );
        assertEq(
            feeManager.vaultCompoundFee(),
            centralRegistry.protocolCompoundFee()
        );
        assertEq(
            feeManager.vaultHarvestFee(),
            centralRegistry.protocolYieldFee() +
                centralRegistry.protocolCompoundFee()
        );
    }
}
