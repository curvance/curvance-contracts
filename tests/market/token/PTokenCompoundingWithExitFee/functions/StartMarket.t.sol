// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBasePTokenCompoundingWithExitFee } from "../TestBasePTokenCompoundingWithExitFee.sol";
import { PTokenBase } from "contracts/market/token/PTokenBase.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract PTokenCompoundingWithExitFeeStartMarketTest is
    TestBasePTokenCompoundingWithExitFee
{
    function test_pTokenCompoundingWithExitFeeStartMarket_fail_whenCallerIsNotMarketManager()
        public
    {
        vm.expectRevert(PTokenBase.PTokenBase__Unauthorized.selector);

        pBALRETHWithExitFee.startMarket(address(0));
    }

    function test_pTokenCompoundingWithExitFeeStartMarket_fail_whenInitializerIsZeroAddress()
        public
    {
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);

        vm.prank(address(marketManager));
        pBALRETHWithExitFee.startMarket(address(0));
    }

    function test_pTokenCompoundingWithExitFeeStartMarket_success() public {
        vm.prank(user1);
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(pBALRETHWithExitFee),
            1e18
        );

        uint256 totalSupply = pBALRETHWithExitFee.totalSupply();

        vm.prank(address(marketManager));
        pBALRETHWithExitFee.startMarket(user1);

        assertEq(pBALRETHWithExitFee.totalSupply(), totalSupply + 42069);
    }
}
