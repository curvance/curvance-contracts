pragma solidity ^0.8.19;

import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseDynamicInterestRateModel } from "../TestBaseDynamicInterestRateModel.sol";

contract DynamicInterestRateModelDeploymentTest is
    TestBaseDynamicInterestRateModel
{
    function test_dynamicInterestRateModelDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry
                .selector
        );
        new DynamicInterestRateModel(
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

    function test_dynamicInterestRateModelDeployment_fail_whenAdjustmentVelocityExceedsMaximum()
        public
    {
        uint256 maxVertexAdjustmentVelocity = 1e18; // Value from the contract

        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__InvalidAdjustmentVelocity
                .selector
        );
        new DynamicInterestRateModel(
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

    function test_dynamicInterestRateModelDeployment_fail_whenBaseInterestRateExceedsMaximum()
        public
    {
        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__InvalidInterestRatePerYear
                .selector
        );
        new DynamicInterestRateModel(
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

    function test_dynamicInterestRateModelDeployment_fail_whenVertexInterestRateExceedsMaximum()
        public
    {
        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__InvalidInterestRatePerYear
                .selector
        );
        new DynamicInterestRateModel(
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

    function test_dynamicInterestRateModelDeployment_fail_whenAdjustmentVelocityIsBelowMinimum()
        public
    {
        uint256 minVertexAdjustmentVelocity = 0.1e18;

        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__InvalidAdjustmentVelocity
                .selector
        );
        new DynamicInterestRateModel(
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

    function test_dynamicInterestRateModelDeployment_fail_whenAdjustmentRateExceedsMaximum()
        public
    {
        uint256 maxVertexAdjustmentRate = 4 hours;

        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__InvalidAdjustmentRate
                .selector
        );
        new DynamicInterestRateModel(
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

    function test_dynamicInterestRateModelDeployment_fail_whenAdjustmentRateIsBelowMinimum()
        public
    {
        uint256 minVertexAdjustmentRate = 20 minutes;

        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__InvalidAdjustmentRate
                .selector
        );
        new DynamicInterestRateModel(
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

    function test_dynamicInterestRateModelDeployment_fail_whenDecayRateExceedsMaximum()
        public
    {
        uint256 maxVertexDecayRate = 0.05e18;

        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__InvalidDecayRate
                .selector
        );
        new DynamicInterestRateModel(
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

    function test_dynamicInterestRateModelDeployment_fail_whenTheoreticalMultiplierOverflows()
        public
    {
        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__InvalidMultiplierMax
                .selector
        );
        new DynamicInterestRateModel(
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

    function test_dynamicInterestRateModelDeployment_success() public {
        interestRateModel = new DynamicInterestRateModel(
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
