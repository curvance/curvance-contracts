// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";

contract ETokenRepayForTest is TestBaseEToken {
    event Repay(address payer, address borrower, uint256 repayAmount);

    function setUp() public override {
        super.setUp();

        _setPBALRETHCollateralCaps(100_000e18);

        _prepareUSDC(address(eUSDC), 2000e6);

        pBALRETH.postCollateral(1e18 - 1);

        _prepareUSDC(address(user1), 1000e6);

        vm.startPrank(user1);
        usdc.approve(address(eUSDC), type(uint256).max);
        eUSDC.mint(100e6, address(this));
        vm.stopPrank();

        eUSDC.borrow(100e6);

        skip(20 minutes);
    }


    function test_eTokenRepayFor_success() public {

        eUSDC.accrueIfNeeded();

       uint256 currentDebt = eUSDC.debtBalance(address(this));

       uint256 underlyingBalance = usdc.balanceOf(address(eUSDC));

        _prepareUSDC(user2, currentDebt);
        vm.startPrank(user2);
        usdc.approve(address(eUSDC), currentDebt);
        
        eUSDC.repayFor(address(this), currentDebt);

        uint256 newDebt = eUSDC.debtBalance(address(this));
        
        assertEq(newDebt, 0);
        assertEq(usdc.balanceOf(user2), 0);
        assertEq(usdc.balanceOf(address(eUSDC)), underlyingBalance + currentDebt);

    }

}
