// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseCurvancePrefarm } from "../TestBaseCurvancePrefarm.sol";
import { CurvancePrefarm } from "contracts/misc/CurvancePrefarm.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract CurvancePrefarmDeploymentTest is TestBaseCurvancePrefarm {
    function test_curvancePrefarmDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert();
        new CurvancePrefarm(
            ICentralRegistry(address(1)),
            manager,
            block.timestamp + 1 weeks
        );
    }

    function test_curvancePrefarmDeployment_success() public {
        uint256 endTimestamp = block.timestamp + 1 weeks;

        curvancePrefarm = new CurvancePrefarm(
            ICentralRegistry(address(centralRegistry)),
            manager,
            endTimestamp
        );
        address[] memory prefarmTokens = new address[](1);
        prefarmTokens[0] = _WETH_ADDRESS;

        vm.startPrank(manager);
        curvancePrefarm.addPrefarmTokens(prefarmTokens);
        vm.stopPrank();

        (bool isApproved, , ) = curvancePrefarm.tokenData(_WETH_ADDRESS);

        assertEq(
            address(curvancePrefarm.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(curvancePrefarm.prefarmManager(), manager);
        assertEq(curvancePrefarm.prefarmEndTimestamp(), endTimestamp);
        assertTrue(isApproved);
    }
}
