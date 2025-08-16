// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { DynamicIRM } from "contracts/market/DynamicIRM.sol";

import { TestBaseDynamicIRM } from "../TestBaseDynamicIRM.sol";

contract UpdateDynamicIRMTest is TestBaseDynamicIRM {
    function test_updateDynamicIRM_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(DynamicIRM.DynamicIRM__Unauthorized.selector);
        IRM.updateDynamicIRM(
            1500,
            1500,
            5500,
            1000,
            150,
            150000000,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenAdjustmentVelocityExceedsMaximum()
        public
    {
        uint256 maxVertexAdjustmentVelocity = 2000;

        vm.expectRevert(
            DynamicIRM.DynamicIRM__InvalidAdjustmentVelocity.selector
        );
        IRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            maxVertexAdjustmentVelocity + 1,
            100,
            100000000,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenAdjustmentVelocityIsBelowMinimum()
        public
    {
        uint256 minVertexAdjustmentVelocity = 100;

        vm.expectRevert(
            DynamicIRM.DynamicIRM__InvalidAdjustmentVelocity.selector
        );

        IRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            minVertexAdjustmentVelocity - 1,
            100,
            100000000,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenDecayRateExceedsMaximum()
        public
    {
        uint256 maxVertexDecayRate = 200;

        vm.expectRevert(DynamicIRM.DynamicIRM__InvalidDecayRate.selector);
        IRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            1000,
            maxVertexDecayRate + 1,
            100000000,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenTheoreticalMultiplierOverflows()
        public
    {
        vm.expectRevert(DynamicIRM.DynamicIRM__InvalidMultiplierMax.selector);
        IRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            1000,
            100,
            uint256(type(uint96).max) + 1,
            true
        );
    }

    function test_updateDynamicIRM_success() public {
        IRM.updateDynamicIRM(
            1500,
            1500,
            5500,
            1000,
            150,
            150000000,
            true
        );
    }
}
