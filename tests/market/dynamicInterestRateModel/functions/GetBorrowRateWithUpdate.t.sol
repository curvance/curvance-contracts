pragma solidity ^0.8.19;

import { TestBaseDynamicInterestRateModel } from "../TestBaseDynamicInterestRateModel.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";

contract GetBorrowRateWithUpdateTest is TestBaseDynamicInterestRateModel {
    uint256 public baseInterestRate;
    uint256 public vertexInterestRate;
    uint256 public vertexPoint;
    uint256 public increaseThreshold;
    uint256 public util;
    uint256 public vertexMultiplier;

    function test_getBorrowRateWithUpdate_fail_whenCallerIsNotLinkedToken()
        public
    {
        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__Unauthorized
                .selector
        );
        interestRateModel.getBorrowRateWithUpdate(0, 0);
    }

    function test_getBorrowRateWithUpdate_success_fuzzed(
        uint256 assetsHeld,
        uint256 borrows,
        uint256 interestFee,
        uint256 timestamp
    ) public {
        vm.assume(assetsHeld < 1e30 && borrows < 1e30);
        vm.assume(interestFee < WAD);
        vm.assume(timestamp < 2000000000);

        vm.warp(timestamp);

        for (uint256 i = 0; i < 3; i++) {
            (
                baseInterestRate,
                vertexInterestRate,
                vertexPoint,
                ,
                ,
                ,
                ,
                increaseThreshold,
                ,
                ,
            ) = interestRateModel.ratesConfig();
            util = interestRateModel.utilizationRate(assetsHeld, borrows);
            vertexMultiplier = interestRateModel.vertexMultiplier();

            uint256 borrowRate = interestRateModel.getBorrowRate(
                assetsHeld,
                borrows
            );
            uint256 supplyRate = interestRateModel.getSupplyRate(
                assetsHeld,
                borrows,
                interestFee
            );
            uint256 predictedBorrowRate = interestRateModel
                .getPredictedBorrowRate(assetsHeld, borrows);

            assertEq(
                supplyRate,
                (util * ((borrowRate * (WAD - interestFee)) / WAD)) / WAD
            );

            vm.prank(address(borrowableCUSDC));
            assertEq(
                interestRateModel.getBorrowRateWithUpdate(
                    assetsHeld,
                    borrows
                ),
                borrowRate
            );

            if (util <= vertexPoint) {
                assertEq(borrowRate, (util * baseInterestRate) / WAD);
                assertEq(predictedBorrowRate, (util * baseInterestRate) / WAD);
            } else {
                assertEq(
                    borrowRate,
                    ((util - vertexPoint) *
                        vertexInterestRate *
                        vertexMultiplier) /
                        WAD_SQUARED +
                        (vertexPoint * baseInterestRate) /
                        WAD
                );

                if (vertexMultiplier == WAD && util < increaseThreshold) {
                    assertEq(predictedBorrowRate, borrowRate);
                }
            }
        }
    }
}
