// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract SetInterestRateModelTest is TestBaseEToken {
    DynamicInterestRateModel public newDynamicInterestRateModel;

    function setUp() public override {
        super.setUp();

        newDynamicInterestRateModel = new DynamicInterestRateModel(
            ICentralRegistry(address(centralRegistry)),
            1000, // baseRatePerYear
            1000, // vertexRatePerYear
            5000, // vertexUtilizationStart
            12 hours, // adjustmentRate
            5000, // adjustmentVelocity
            100000000, // 1000x maximum vertex multiplier
            100 // decayRate
        );
    }

    function test_setInterestRateModel_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(EToken.EToken__Unauthorized.selector);
        eUSDC.setInterestRateModel(address(newDynamicInterestRateModel));
    }

    function test_setInterestRateModel_fail_whenInvalidInterestRateModel()
        public
    {
        vm.expectRevert();
        eUSDC.setInterestRateModel(address(1));
    }

    function test_setInterestRateModel_success() public {
        assertEq(
            address(eUSDC.interestRateModel()),
            address(interestRateModels[block.chainid][_USDC_ADDRESS])
        );

        eUSDC.setInterestRateModel(address(newDynamicInterestRateModel));

        assertEq(
            address(eUSDC.interestRateModel()),
            address(newDynamicInterestRateModel)
        );
    }
}
