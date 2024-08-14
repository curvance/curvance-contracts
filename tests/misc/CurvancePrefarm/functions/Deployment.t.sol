// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseCurvancePrefarm } from "../TestBaseCurvancePrefarm.sol";
import { CurvancePrefarm } from "contracts/misc/CurvancePrefarm.sol";

contract CurvancePrefarmDeploymentTest is TestBaseCurvancePrefarm {
    function test_curvancePrefarmDeployment_success() public {
        uint256 endTimestamp = block.timestamp + 1 weeks;

        curvancePrefarm = new CurvancePrefarm(manager, endTimestamp);

        assertEq(curvancePrefarm.prefarmManager(), manager);
        assertEq(curvancePrefarm.prefarmEndTimestamp(), endTimestamp);
    }
}
