// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract BorrowableCTokenRescueTokenTest is TestBaseBorrowableCToken {
    function setUp() public override {
        super.setUp();

        deal(address(borrowableCUSDC), _ONE);
        _prepareDAI(address(borrowableCUSDC), _ONE);
    }

    function test_borrowableCTokenRescueToken_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        borrowableCUSDC.rescueToken(_USDC_ADDRESS, 100);
    }

    function test_borrowableCTokenRescueToken_fail_whenETHAmountExceedsBalance() public {
        uint256 balance = address(borrowableCUSDC).balance;

        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        borrowableCUSDC.rescueToken(address(0), balance + 1);
    }

    function test_borrowableCTokenRescueToken_fail_whenTokenIsUnderlyingToken() public {
        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        borrowableCUSDC.rescueToken(_USDC_ADDRESS, 100);
    }

    function test_borrowableCTokenRescueToken_fail_whenTokenAmountExceedsBalance()
        public
    {
        uint256 balance = dai.balanceOf(address(borrowableCUSDC));

        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        borrowableCUSDC.rescueToken(_DAI_ADDRESS, balance + 1);
    }

    function test_borrowableCTokenRescueToken_success() public {
        address daoOperator = centralRegistry.daoAddress();

        uint256 ethBalance = address(borrowableCUSDC).balance;
        uint256 daiBalance = dai.balanceOf(address(borrowableCUSDC));
        uint256 daoOperatorEthBalance = daoOperator.balance;
        uint256 daoOperatorDaiBalance = dai.balanceOf(daoOperator);

        borrowableCUSDC.rescueToken(address(0), 100);
        borrowableCUSDC.rescueToken(_DAI_ADDRESS, 100);

        assertEq(address(borrowableCUSDC).balance, ethBalance - 100);
        assertEq(dai.balanceOf(address(borrowableCUSDC)), daiBalance - 100);
        assertEq(daoOperator.balance, daoOperatorEthBalance + 100);
        assertEq(dai.balanceOf(daoOperator), daoOperatorDaiBalance + 100);
    }

    receive() external payable {}
}
