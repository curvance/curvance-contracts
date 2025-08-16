// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { StrategyCToken } from "contracts/market/token/StrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract StrategyCTokenRescueTokenTest is TestBaseStrategyCToken {
    function setUp() public override {
        super.setUp();

        deal(address(strategyCBALRETH), _ONE);
        _prepareDAI(address(strategyCBALRETH), _ONE);
    }

    function test_RescueToken_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        strategyCBALRETH.rescueToken(_BAL_WETH_RETH_ADDRESS, 100);
    }

    function test_borrowableCTokenRescueToken_fail_whenETHAmountExceedsBalance() public {
        uint256 balance = address(strategyCBALRETH).balance;

        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        strategyCBALRETH.rescueToken(address(0), balance + 1);
    }

    function test_borrowableCTokenRescueToken_fail_whenTokenIsUnderlyingToken() public {
        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        strategyCBALRETH.rescueToken(_BAL_WETH_RETH_ADDRESS, 100);
    }

    function test_borrowableCTokenRescueToken_fail_whenTokenAmountExceedsBalance()
        public
    {
        uint256 balance = dai.balanceOf(address(strategyCBALRETH));

        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        strategyCBALRETH.rescueToken(_DAI_ADDRESS, balance + 1);
    }

    function test_borrowableCTokenRescueToken_success() public {
        address daoOperator = centralRegistry.daoAddress();

        uint256 ethBalance = address(strategyCBALRETH).balance;
        uint256 daiBalance = dai.balanceOf(address(strategyCBALRETH));
        uint256 daoOperatorEthBalance = daoOperator.balance;
        uint256 daoOperatorDaiBalance = dai.balanceOf(daoOperator);

        strategyCBALRETH.rescueToken(address(0), 100);
        strategyCBALRETH.rescueToken(_DAI_ADDRESS, 100);

        assertEq(address(strategyCBALRETH).balance, ethBalance - 100);
        assertEq(dai.balanceOf(address(strategyCBALRETH)), daiBalance - 100);
        assertEq(daoOperator.balance, daoOperatorEthBalance + 100);
        assertEq(dai.balanceOf(daoOperator), daoOperatorDaiBalance + 100);
    }

    receive() external payable {}
}
