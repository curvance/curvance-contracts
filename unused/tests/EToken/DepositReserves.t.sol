// // SPDX-License-Identifier: GPL-3.0
// pragma solidity ^0.8.19;

// import { TestBaseEToken } from "../TestBaseEToken.sol";
// import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
// import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

// contract ETokenDepositReservesTest is TestBaseEToken {
//     function test_eTokenDepositReserves_fail_whenCallIsNotAuthorized() public {
//         vm.prank(address(1));

//         vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
//         borrowableCUSDC.depositReserves(100e6);
//     }

//     function test_eTokenDepositReserves_fail_whenAmountIsZero() public {
//         vm.expectRevert(BaseCToken.BaseCToken__EmptyAction.selector);
//         borrowableCUSDC.depositReserves(0);
//     }

//     function test_eTokenDepositReserves_success() public {
//         uint256 underlyingBalance = usdc.balanceOf(address(this));
//         uint256 balance = borrowableCUSDC.balanceOf(address(this));
//         uint256 totalSupply = borrowableCUSDC.totalSupply();

//         borrowableCUSDC.depositReserves(100e6);

//         assertEq(usdc.balanceOf(address(this)), underlyingBalance - 100e6);
//         assertEq(borrowableCUSDC.balanceOf(address(this)), balance);
//         assertEq(borrowableCUSDC.totalSupply(), totalSupply);
//     }
// }
