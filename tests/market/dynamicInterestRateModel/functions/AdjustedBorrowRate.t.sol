// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { DynamicIRM } from "contracts/market/DynamicIRM.sol";

import { BPS, WAD, WAD_SQUARED } from "contracts/libraries/ConstantsLib.sol";

import { TestBaseDynamicIRM } from "../TestBaseDynamicIRM.sol";

contract AdjustedBorrowRateTest is TestBaseDynamicIRM {
    uint256 public baseRatePerSecond;
    uint256 public vertexRatePerSecond;
    uint256 public vertexStart;
    uint256 public increaseThresholdStart;
    uint256 public util;
    uint256 public vertexMultiplier;

    function test_adjustedBorrowRate_fail_whenCallerIsNotLinkedToken()
        public
    {
        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__Unauthorized
                .selector
        );
        IRM.adjustedBorrowRate(0, 0);
    }

    function test_adjustedBorrowRate_success_fuzzed(
        uint256 assetsHeld,
        uint256 borrows,
        uint256 interestFee,
        uint256 timestamp
    ) public {
        vm.assume(assetsHeld < 1e30 && borrows < 1e30);
        vm.assume(interestFee < BPS);
        vm.assume(timestamp < 2000000000);

        vm.warp(timestamp);
        for (uint256 i = 0; i < 3; i++) {
            (
                baseRatePerSecond,
                vertexRatePerSecond,
                vertexStart,
                ,
                ,
                increaseThresholdStart,
                ,
                ,
            ) = IRM.ratesConfig();

            util = IRM.utilizationRate(assetsHeld, borrows);
            vertexMultiplier = IRM.vertexMultiplier();

            uint256 borrowRate = IRM.borrowRate(
                assetsHeld,
                borrows
            );
            uint256 supplyRate = IRM.supplyRate(
                assetsHeld,
                borrows,
                interestFee
            );
            uint256 predictedBorrowRate = IRM
                .predictedBorrowRate(assetsHeld, borrows);

            // Utilization is in WAD and interestFee in BPS.
            assertEq(
                supplyRate,
                (util * ((borrowRate * (BPS - interestFee)) / BPS)) / WAD
            );

            vm.prank(address(borrowableCUSDC));
            (uint256 adjustedRate, ) = IRM.adjustedBorrowRate(assetsHeld, borrows);
            assertEq(adjustedRate, borrowRate);

            if (util <= vertexStart) {
                assertEq(borrowRate, (util * baseRatePerSecond) / WAD);
                assertEq(predictedBorrowRate, (util * baseRatePerSecond) / WAD);
            } else {
                assertEq(
                    borrowRate,
                    ((util - vertexStart) *
                        vertexRatePerSecond *
                        vertexMultiplier) /
                        WAD_SQUARED +
                        (vertexStart * baseRatePerSecond) /
                        WAD
                );

                if (vertexMultiplier == WAD && util < increaseThresholdStart) {
                    assertEq(predictedBorrowRate, borrowRate);
                }
            }
        }
    }
}
