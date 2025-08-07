// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract SetIRMTest is TestBaseBorrowableCToken {
    DynamicIRM public newDynamicIRM;

    function setUp() public override {
        super.setUp();

        newDynamicIRM = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000, // baseRatePerYear
            1000, // vertexRatePerYear
            5000, // vertexUtilizationStart
            1000, // adjustmentVelocity
            100000000, // 1000x maximum vertex multiplier
            100 // decayRate
        );
    }

    function test_setIRM_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        borrowableCUSDC.setIRM(address(newDynamicIRM));
    }

    function test_setIRM_fail_whenInvalidIRM()
        public
    {
        vm.expectRevert();
        borrowableCUSDC.setIRM(address(1));
    }

    function test_setIRM_success() public {
        assertEq(
            address(borrowableCUSDC.IRM()),
            address(IRMs[block.chainid][_USDC_ADDRESS])
        );

        borrowableCUSDC.setIRM(address(newDynamicIRM));

        assertEq(
            address(borrowableCUSDC.IRM()),
            address(newDynamicIRM)
        );
    }

    function test_setIRM_success_withOutstandingDebt() public {
        borrowableCUSDC.deposit(200e6, address(this));
        strategyCBALRETH.postCollateral(1e18 - 1);
        borrowableCUSDC.borrow(100e6, address(this));

        _harvestAuraStrategyRewards(1 weeks);

        uint256 debtBeforeAccrual = borrowableCUSDC.debtBalance(address(this));
        uint256 totalAssetsBeforeAccrual = borrowableCUSDC.totalAssets();

        assertEq(address(borrowableCUSDC.IRM()), address(IRMs[block.chainid][_USDC_ADDRESS])
        );

        borrowableCUSDC.setIRM(address(newDynamicIRM));

        uint256 debtAfterAccrual = borrowableCUSDC.debtBalance(address(this));
        uint256 totalAssetsAfterAccrual = borrowableCUSDC.totalAssets();

        assertEq(address(borrowableCUSDC.IRM()), address(newDynamicIRM));

        assertGt(debtAfterAccrual, 100e6);
        assertGt(debtAfterAccrual, debtBeforeAccrual);

        uint256 debtIncrease = debtAfterAccrual - debtBeforeAccrual;
        uint256 assetsIncrease = totalAssetsAfterAccrual - totalAssetsBeforeAccrual;
        assertEq(debtIncrease, assetsIncrease);
    }
}
