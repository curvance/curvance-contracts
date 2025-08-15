// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract BorrowableCTokenInitializeDepositsTest is TestBaseBorrowableCToken {
    
    function test_borrowableCTokenInitializeDeposits_fail_whenCallerIsNotMarketManager()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        borrowableCUSDC.initializeDeposits(address(0));
    }

    function test_borrowableCTokenInitializeDeposits_fail_whenIRMLinkedToWrongToken()
        public
    {
        borrowableCUSDC.setIRM(
            address(IRMs[block.chainid][_DAI_ADDRESS])
        );

        vm.prank(address(marketManagerIsolated));

        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        borrowableCUSDC.initializeDeposits(user1);
    }

    function test_borrowableCTokenInitializeDeposits_fail_whenInitializerIsZeroAddress()
        public
    {
        vm.prank(address(marketManagerIsolated));

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        borrowableCUSDC.initializeDeposits(address(0));
    }

    function test_borrowableCTokenInitializeDeposits_success() public {
        _prepareUSDC(address(user1), 1000e6);

        vm.startPrank(user1);
        SafeTransferLib.safeApprove(_USDC_ADDRESS, address(borrowableCUSDC), 1e18);
        vm.stopPrank();

        uint256 totalSupply = borrowableCUSDC.totalSupply();

        vm.prank(address(marketManagerIsolated));
        borrowableCUSDC.initializeDeposits(user1);

        assertEq(borrowableCUSDC.totalSupply(), totalSupply + 77777);
    }
}
