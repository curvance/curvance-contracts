// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FeeManager } from "contracts/architecture/FeeManager.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseFeeManager } from "../TestBaseFeeManager.sol";

contract FeeManagerDeploymentTest is TestBaseFeeManager {
    function test_feeManagerDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry
                .selector
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
