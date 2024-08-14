// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseCurvancePrefarm } from "../TestBaseCurvancePrefarm.sol";
import { CurvancePrefarm } from "contracts/misc/CurvancePrefarm.sol";

contract CurvancePrefarmDeploymentTest is TestBaseCurvancePrefarm {
    function test_curvancePrefarmDeployment_success() public {
        uint256 endTimestamp = block.timestamp + 1 weeks;

        curvancePrefarm = new CurvancePrefarm(manager, endTimestamp);
        address[] memory prefarmTokens = new address[](1);
        prefarmTokens[0] = _USDC_ADDRESS;

        vm.startPrank(manager);
        addPrefarmTokens(prefarmTokens);
        vm.stopPrank();

        assertEq(curvancePrefarm.prefarmManager(), manager);
        assertEq(curvancePrefarm.prefarmEndTimestamp(), endTimestamp);
        assertEq(curvancePrefarm.tokenData(_USDC_ADDRESS).isApproved, true);
    }
}
