// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBasePTokenCompounding } from "../TestBasePTokenCompounding.sol";
import { PTokenBase } from "contracts/market/token/PTokenBase.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract PTokenCompoundingStartMarketTest is TestBasePTokenCompounding {
    function test_pTokenCompoundingStartMarket_fail_whenCallerIsNotMarketManager()
        public
    {
        vm.expectRevert(PTokenBase.PTokenBase__Unauthorized.selector);

        pBALRETH.startMarket(address(0));
    }

    function test_pTokenCompoundingStartMarket_fail_whenInitializerIsZeroAddress()
        public
    {
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);

        vm.prank(address(marketManager));
        pBALRETH.startMarket(address(0));
    }

    function test_pTokenCompoundingStartMarket_success() public {
        vm.prank(user1);
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(pBALRETH),
            1e18
        );

        uint256 totalSupply = pBALRETH.totalSupply();

        vm.prank(address(marketManager));
        pBALRETH.startMarket(user1);

        assertEq(pBALRETH.totalSupply(), totalSupply + 42069);
    }
}
