// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract SetInteresFeeTest is TestBaseEToken {
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
        assertEq(borrowableCUSDC.interestFee(), 0.1e18);

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit NewInterestFee(0.1e18, 0.5e18);

        borrowableCUSDC.setInterestFee(5000);

        assertEq(borrowableCUSDC.interestFee(), 0.5e18);
    }
}
