// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { EToken } from "contracts/market/token/EToken.sol";

contract ETokenRepayForTest is TestBaseEToken {
    event Repay(address payer, address borrower, uint256 repayAmount);

    function setUp() public override {
        super.setUp();

        _setPBALRETHCollateralCaps(100_000e18);

        _prepareUSDC(address(eUSDC), 2000e6);

        pBALRETH.postCollateral(1e18 - 1);

        vm.prank(user1);
        eUSDC.mintFor(100e6, address(this));

        eUSDC.borrow(100e6);

        skip(20 minutes);
    }


    function test_eTokenRepayFor_success() public {

        eUSDC.accrueInterest();

       uint256 currentDebt = eUSDC.debtBalanceCached(address(this));

       uint256 underlyingBalance = usdc.balanceOf(address(eUSDC));

        _prepareUSDC(user2, currentDebt);
        vm.startPrank(user2);
        usdc.approve(address(eUSDC), currentDebt);
        
        eUSDC.repayFor(address(this), currentDebt);

        uint256 newDebt = eUSDC.debtBalanceCached(address(this));
        
        assertEq(newDebt, 0);
        assertEq(usdc.balanceOf(user2), 0);
        assertEq(usdc.balanceOf(address(eUSDC)), underlyingBalance + currentDebt);

    }

}
