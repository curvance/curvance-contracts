// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";

contract SetInterestFactorTest is TestBaseEToken {
    event NewInterestFactor(
        uint256 oldInterestFactor,
        uint256 newInterestFactor
    );

    function test_setInterestFactor_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(BorrowableCToken.BorrowableCToken__Unauthorized.selector);
        eUSDC.setInterestFactor(5000);
    }

    function test_setInterestFactor_fail_whenInvalidInterestFactor() public {
        vm.expectRevert(BorrowableCToken.BorrowableCToken__ExcessiveValue.selector);
        eUSDC.setInterestFactor(5001);
    }

    function test_setInterestFactor_success() public {
        assertEq(eUSDC.interestFactor(), 0.1e18);

        vm.expectEmit(true, true, true, true, address(eUSDC));
        emit NewInterestFactor(0.1e18, 0.5e18);

        eUSDC.setInterestFactor(5000);

        assertEq(eUSDC.interestFactor(), 0.5e18);
    }
}
