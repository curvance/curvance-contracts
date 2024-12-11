// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";
import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";

contract VeCVEDeploymentTest is TestBaseVeCVE {
    function test_veCVEDeployment_fail_whenCentralRegistryIsInvalid() public {
        vm.expectRevert(VeCVE.VeCVE__ParametersAreInvalid.selector);
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
