// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseCurvancePrefarm } from "../TestBaseCurvancePrefarm.sol";
import { CurvancePrefarm } from "contracts/misc/CurvancePrefarm.sol";

contract CurvancePrefarmDeploymentTest is TestBaseCurvancePrefarm {
    function test_curvancePrefarmDeployment_success() public {
        uint256 endTimestamp = block.timestamp + 1 weeks;

        curvancePrefarm = new CurvancePrefarm(manager, endTimestamp);
        address[] memory prefarmTokens = new address[](1);
        prefarmTokens[0] = _WETH_ADDRESS;

        vm.startPrank(manager);
        curvancePrefarm.addPrefarmTokens(prefarmTokens);
        vm.stopPrank();

        (bool isApproved, , ) = curvancePrefarm.tokenData(_WETH_ADDRESS);

        assertEq(curvancePrefarm.prefarmManager(), manager);
        assertEq(curvancePrefarm.prefarmEndTimestamp(), endTimestamp);
        assertEq(isApproved, true);
    }
}
