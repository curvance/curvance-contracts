// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseCompoundingWithExitFeePToken } from "../TestBaseCompoundingWithExitFeePToken.sol";
import { BasePToken } from "contracts/market/token/BasePToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract CompoundingWithExitFeePTokenStartMarketTest is
    TestBaseCompoundingWithExitFeePToken
{
    function test_compoundingWithExitFeePTokenStartMarket_fail_whenCallerIsNotMarketManager()
        public
    {
        vm.expectRevert(BasePToken.BasePToken__Unauthorized.selector);

        pBALRETHWithExitFee.startMarket(address(0));
    }

    function test_compoundingWithExitFeePTokenStartMarket_fail_whenInitializerIsZeroAddress()
        public
    {
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);

        vm.prank(address(marketManagerIsolated));
        pBALRETHWithExitFee.startMarket(address(0));
    }

    function test_compoundingWithExitFeePTokenStartMarket_success() public {
        vm.prank(user1);
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(pBALRETHWithExitFee),
            1e18
        );

        uint256 totalSupply = pBALRETHWithExitFee.totalSupply();

        vm.prank(address(marketManagerIsolated));
        pBALRETHWithExitFee.startMarket(user1);

        assertEq(pBALRETHWithExitFee.totalSupply(), totalSupply + 42069);
    }
}
