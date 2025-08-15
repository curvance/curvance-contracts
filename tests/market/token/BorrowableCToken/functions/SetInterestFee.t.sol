// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract SetInterestFeeTest is TestBaseBorrowableCToken {
    event NewInterestFee(
        uint256 oldInterestFee,
        uint256 newInterestFee
    );

    function test_setInterestFee_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        borrowableCUSDC.setInterestFee(5000);
    }

    function test_setInterestFee_fail_whenInvalidInterestFee() public {
        vm.expectRevert(BorrowableCToken.BorrowableCToken__InvalidParameter.selector);
        borrowableCUSDC.setInterestFee(5001);
    }

    function test_setInterestFee_success() public {
        assertEq(borrowableCUSDC.interestFee(), 1000);

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit NewInterestFee(1000, 5000);

        borrowableCUSDC.setInterestFee(5000);

        assertEq(borrowableCUSDC.interestFee(), 5000);
    }

    function test_setInterestFee_success_withOutstandingDebt() public {
        borrowableCUSDC.deposit(200e6, address(this));
        strategyCBALRETH.postCollateral(1e18 - 1);
        borrowableCUSDC.borrow(100e6, address(this));

        _harvestAuraStrategyRewards(1 weeks);

        uint256 debtBeforeAccrual = borrowableCUSDC.debtBalance(address(this));
        uint256 totalAssetsBeforeAccrual = borrowableCUSDC.totalAssets();

        assertEq(borrowableCUSDC.interestFee(), 1000);

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit NewInterestFee(1000, 2000);

        borrowableCUSDC.setInterestFee(2000);
        borrowableCUSDC.accrueIfNeeded();

        uint256 debtAfterAccrual = borrowableCUSDC.debtBalance(address(this));
        uint256 totalAssetsAfterAccrual = borrowableCUSDC.totalAssets();

        assertEq(borrowableCUSDC.interestFee(), 2000);

        assertGt(debtAfterAccrual, 100e6);
        assertGt(debtAfterAccrual, debtBeforeAccrual);

        uint256 debtIncrease = debtAfterAccrual - debtBeforeAccrual;
        uint256 assetsIncrease = totalAssetsAfterAccrual - totalAssetsBeforeAccrual;
        assertEq(debtIncrease, assetsIncrease);
    }
}
