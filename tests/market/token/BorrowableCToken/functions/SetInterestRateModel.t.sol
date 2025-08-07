// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract SetInterestRateModelTest is TestBaseBorrowableCToken {
    DynamicInterestRateModel public newDynamicInterestRateModel;

    function setUp() public override {
        super.setUp();

        newDynamicInterestRateModel = new DynamicInterestRateModel(
            ICentralRegistry(address(centralRegistry)),
            1000, // baseRatePerYear
            1000, // vertexRatePerYear
            5000, // vertexUtilizationStart
            4 hours, // adjustmentRate
            5000, // adjustmentVelocity
            100000000, // 1000x maximum vertex multiplier
            100 // decayRate
        );
    }

    function test_setInterestRateModel_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        borrowableCUSDC.setInterestRateModel(address(newDynamicInterestRateModel));
    }

    function test_setInterestRateModel_fail_whenInvalidInterestRateModel()
        public
    {
        vm.expectRevert();
        borrowableCUSDC.setInterestRateModel(address(1));
    }

    function test_setInterestRateModel_success() public {
        assertEq(
            address(borrowableCUSDC.interestRateModel()),
            address(interestRateModels[block.chainid][_USDC_ADDRESS])
        );

        borrowableCUSDC.setInterestRateModel(address(newDynamicInterestRateModel));

        assertEq(
            address(borrowableCUSDC.interestRateModel()),
            address(newDynamicInterestRateModel)
        );
    }

    function test_setInterestRateModel_success_withOutstandingDebt() public {
        borrowableCUSDC.deposit(200e6, address(this));
        strategyCBALRETH.postCollateral(1e18 - 1);
        borrowableCUSDC.borrow(100e6, address(this));
        
        _harvestAuraStrategyRewards(1 weeks);

        uint256 debtBeforeAccrual = borrowableCUSDC.debtBalance(address(this));
        uint256 totalAssetsBeforeAccrual = borrowableCUSDC.totalAssets();

        assertEq(address(borrowableCUSDC.interestRateModel()), address(interestRateModels[block.chainid][_USDC_ADDRESS])
        );

        borrowableCUSDC.setInterestRateModel(address(newDynamicInterestRateModel));

        uint256 debtAfterAccrual = borrowableCUSDC.debtBalance(address(this));
        uint256 totalAssetsAfterAccrual = borrowableCUSDC.totalAssets();

        assertEq(address(borrowableCUSDC.interestRateModel()),address(newDynamicInterestRateModel)
        );

        assertGt(debtAfterAccrual, 100e6);
        assertGt(debtAfterAccrual, debtBeforeAccrual);

        uint256 debtIncrease = debtAfterAccrual - debtBeforeAccrual;
        uint256 assetsIncrease = totalAssetsAfterAccrual - totalAssetsBeforeAccrual;
        assertEq(debtIncrease, assetsIncrease);
    }
}
