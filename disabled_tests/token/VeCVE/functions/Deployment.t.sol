// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { VeCVE } from "contracts/token/VeCVE.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";

contract VeCVEDeploymentTest is TestBaseVeCVE {
    function test_veCVEDeployment_fail_whenCentralRegistryIsInvalid() public {
        vm.expectRevert(
            CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry
                .selector
        );
        new VeCVE(ICentralRegistry(address(1)));
    }

    function test_veCVEDeployment_success() public {
        veCVE = new VeCVE(ICentralRegistry(address(centralRegistry)));

        assertEq(veCVE.name(), "Vote Escrowed CVE");
        assertEq(veCVE.symbol(), "veCVE");
        assertEq(address(veCVE.centralRegistry()), address(centralRegistry));
        assertEq(veCVE.CL_POINT_MULTIPLIER(), 2);
    }
}
