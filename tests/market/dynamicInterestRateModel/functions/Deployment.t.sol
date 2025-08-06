pragma solidity ^0.8.19;

import { DynamicIRM } from "contracts/market/DynamicIRM.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseDynamicIRM } from "../TestBaseDynamicIRM.sol";

contract DynamicIRMDeploymentTest is TestBaseDynamicIRM {
    function test_dynamicIRMDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry
                .selector
        );
        new DynamicIRM(
            ICentralRegistry(address(0)),
            1000,
            1000,
            5000,
            12 hours,
            5000,
            100000000,
            100
        );
    }

    function test_dynamicIRMDeployment_fail_whenAdjustmentVelocityExceedsMaximum()
        public
    {
        uint256 maxVertexAdjustmentVelocity = 1e18; // Value from the contract

        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidAdjustmentVelocity
                .selector
        );
        new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            12 hours,
            (maxVertexAdjustmentVelocity) / 1e14 + 1,
            100000000,
            100
        );
    }

    function test_dynamicIRMDeployment_fail_whenBaseInterestRateExceedsMaximum()
        public
    {
        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidInterestRatePerYear
                .selector
        );
        new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            15001,
            1000,
            5000,
            12 hours,
            5000,
            100000000,
            100
        );
    }

    function test_dynamicIRMDeployment_fail_whenVertexInterestRateExceedsMaximum()
        public
    {
        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidInterestRatePerYear
                .selector
        );
        new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            20001,
            5000,
            12 hours,
            5000,
            100000000,
            100
        );
    }

    function test_dynamicIRMDeployment_fail_whenAdjustmentVelocityIsBelowMinimum()
        public
    {
        uint256 minVertexAdjustmentVelocity = 0.1e18;

        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidAdjustmentVelocity
                .selector
        );
        new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            12 hours,
            (minVertexAdjustmentVelocity) / 1e14 - 1,
            100000000,
            100
        );
    }

    function test_dynamicIRMDeployment_fail_whenAdjustmentRateExceedsMaximum()
        public
    {
        uint256 maxVertexAdjustmentRate = 4 hours;

        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidAdjustmentRate
                .selector
        );
        new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            maxVertexAdjustmentRate + 1,
            5000,
            100000000,
            100
        );
    }

    function test_dynamicIRMDeployment_fail_whenAdjustmentRateIsBelowMinimum()
        public
    {
        uint256 minVertexAdjustmentRate = 20 minutes;

        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidAdjustmentRate
                .selector
        );
        new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            minVertexAdjustmentRate - 1,
            5000,
            100000000,
            100
        );
    }

    function test_dynamicIRMDeployment_fail_whenDecayRateExceedsMaximum()
        public
    {
        uint256 maxVertexDecayRate = 0.05e18;

        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidDecayRate
                .selector
        );
        new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            4 hours,
            5000,
            100000000,
            (maxVertexDecayRate / 1e14) + 1
        );
    }

    function test_dynamicIRMDeployment_fail_whenTheoreticalMultiplierOverflows()
        public
    {
        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidMultiplierMax
                .selector
        );
        new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            4 hours,
            5000,
            type(uint192).max / (1000 * 1e14) / 1e14 + 1,
            100
        );
    }

    function test_dynamicIRMDeployment_success() public {
        IRM = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1500,
            1500,
            5500,
            4 hours,
            5500,
            150000000,
            150
        );
    }
}
