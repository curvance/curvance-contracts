// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

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
            1000,
            100,
            100000000
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
            1000,
            100,
            100000000
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
            1000,
            100,
            100000000
        );
    }

    function test_dynamicIRMDeployment_fail_whenAdjustmentVelocityExceedsMaximum()
        public
    {
        uint256 maxVertexAdjustmentVelocity = 2000; // Value from the contract

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
            maxVertexAdjustmentVelocity + 1,
            100,
            100000000
        );
    }

    function test_dynamicIRMDeployment_fail_whenAdjustmentVelocityIsBelowMinimum()
        public
    {
        uint256 minVertexAdjustmentVelocity = 100;

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
            minVertexAdjustmentVelocity - 1,
            100,
            100000000
        );
    }

    function test_dynamicIRMDeployment_fail_whenDecayRateExceedsMaximum()
        public
    {
        uint256 maxVertexDecayRate = 200;

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
            1000,
            maxVertexDecayRate + 1,
            100000000
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
            1000,
            100,
            uint256(type(uint96).max) + 1
        );
    }

    function test_dynamicIRMDeployment_success() public {
        IRM = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1500,
            1500,
            5500,
            1000,
            150,
            150000000
        );
    }
}
