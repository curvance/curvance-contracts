// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract StrategyCTokenWithExitFeeInitializeDepositsTest is
    TestBaseStrategyCTokenWithExitFee
{
    function test_strategyCTokenWithExitFeeInitializeDeposits_fail_whenCallerIsNotMarketManager()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);

        strategyCBALRETHWithExitFee.initializeDeposits(address(0));
    }

    function test_strategyCTokenWithExitFeeInitializeDeposits_fail_whenInitializerIsZeroAddress()
        public
    {
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);

        vm.prank(address(marketManagerIsolated));
        strategyCBALRETHWithExitFee.initializeDeposits(address(0));
    }

    function test_strategyCTokenWithExitFeeInitializeDeposits_success() public {
        vm.prank(user1);
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(strategyCBALRETHWithExitFee),
            1e18
        );

        uint256 totalSupply = strategyCBALRETHWithExitFee.totalSupply();

        vm.prank(address(marketManagerIsolated));
        strategyCBALRETHWithExitFee.initializeDeposits(user1);

        assertEq(strategyCBALRETHWithExitFee.totalSupply(), totalSupply + 77777);
    }
}
