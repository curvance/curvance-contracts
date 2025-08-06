pragma solidity ^0.8.19;

import { TestBaseDynamicIRM } from "../TestBaseDynamicIRM.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";

contract UpdateDynamicIRMTest is
    TestBaseDynamicIRM
{
    function test_updateDynamicIRM_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__Unauthorized
                .selector
        );
        IRM.updateDynamicIRM(
            1500,
            1500,
            5500,
            4 hours,
            5500,
            150000000,
            150,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenAdjustmentVelocityExceedsMaximum()
        public
    {
        uint256 maxVertexAdjustmentVelocity = 1e18;

        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidAdjustmentVelocity
                .selector
        );
        IRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            12 hours,
            (maxVertexAdjustmentVelocity) / 1e14 + 1,
            100000000,
            100,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenAdjustmentVelocityIsBelowMinimum()
        public
    {
        uint256 minVertexAdjustmentVelocity = 0.1e18;

        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidAdjustmentVelocity
                .selector
        );

        IRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            12 hours,
            (minVertexAdjustmentVelocity / 1e14) - 1,
            100000000,
            100,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenAdjustmentRateExceedsMaximum()
        public
    {
        uint256 maxVertexAdjustmentRate = 4 hours;

        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidAdjustmentRate
                .selector
        );
        IRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            maxVertexAdjustmentRate + 1,
            5000,
            100000000,
            100,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenAdjustmentRateIsBelowMinimum()
        public
    {
        uint256 minVertexAdjustmentRate = 20 minutes;

        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidAdjustmentRate
                .selector
        );
        IRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            minVertexAdjustmentRate - 1,
            5000,
            100000000,
            100,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenDecayRateExceedsMaximum()
        public
    {
        uint256 maxVertexDecayRate = 0.05e18;

        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidDecayRate
                .selector
        );
        IRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            4 hours,
            5000,
            100000000,
            (maxVertexDecayRate / 1e14) + 1,
            true
        );
    }

    function test_updateDynamicIRM_fail_whenTheoreticalMultiplierOverflows()
        public
    {
        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidMultiplierMax
                .selector
        );
        IRM.updateDynamicIRM(
            1000,
            1000,
            5000,
            4 hours,
            5000,
            type(uint192).max / (1000 * 1e14) / 1e14 + 1,
            100,
            true
        );
    }

    function test_updateDynamicIRM_success() public {
        IRM.updateDynamicIRM(
            1500,
            1500,
            5500,
            4 hours,
            5500,
            150000000,
            150,
            true
        );
    }
}
