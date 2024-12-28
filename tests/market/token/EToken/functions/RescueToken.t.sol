// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract ETokenRescueTokenTest is TestBaseEToken {
    function setUp() public override {
        super.setUp();

        deal(address(eUSDC), _ONE);
        _prepareDAI(address(eUSDC), _ONE);
    }

    function test_eTokenRescueToken_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(EToken.EToken__Unauthorized.selector);
        eUSDC.rescueToken(_USDC_ADDRESS, 100);
    }

    function test_eTokenRescueToken_fail_whenETHAmountExceedsBalance() public {
        uint256 balance = address(eUSDC).balance;

        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        eUSDC.rescueToken(address(0), balance + 1);
    }

    function test_eTokenRescueToken_fail_whenTokenIsUnderlyingToken() public {
        vm.expectRevert(EToken.EToken__TransferError.selector);
        eUSDC.rescueToken(_USDC_ADDRESS, 100);
    }

    function test_eTokenRescueToken_fail_whenTokenAmountExceedsBalance()
        public
    {
        uint256 balance = dai.balanceOf(address(eUSDC));

        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        eUSDC.rescueToken(_DAI_ADDRESS, balance + 1);
    }

    function test_eTokenRescueToken_success() public {
        address daoOperator = centralRegistry.daoAddress();

        uint256 ethBalance = address(eUSDC).balance;
        uint256 daiBalance = dai.balanceOf(address(eUSDC));
        uint256 daoOperatorEthBalance = daoOperator.balance;
        uint256 daoOperatorDaiBalance = dai.balanceOf(daoOperator);

        eUSDC.rescueToken(address(0), 100);
        eUSDC.rescueToken(_DAI_ADDRESS, 100);

        assertEq(address(eUSDC).balance, ethBalance - 100);
        assertEq(dai.balanceOf(address(eUSDC)), daiBalance - 100);
        assertEq(daoOperator.balance, daoOperatorEthBalance + 100);
        assertEq(dai.balanceOf(daoOperator), daoOperatorDaiBalance + 100);
    }

    receive() external payable {}
}
