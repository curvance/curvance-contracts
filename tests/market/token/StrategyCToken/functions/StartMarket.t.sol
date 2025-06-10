// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BasePToken } from "contracts/market/token/BasePToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract StrategyCTokenStartMarketTest is TestBaseStrategyCToken {
    function test_strategyCTokenStartMarket_fail_whenCallerIsNotMarketManager()
        public
    {
        vm.expectRevert(BasePToken.BasePToken__Unauthorized.selector);

        pBALRETH.startMarket(address(0));
    }

    function test_strategyCTokenStartMarket_fail_whenInitializerIsZeroAddress()
        public
    {
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);

        vm.prank(address(marketManagerIsolated));
        pBALRETH.startMarket(address(0));
    }

    function test_strategyCTokenStartMarket_success() public {
        vm.prank(user1);
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(pBALRETH),
            1e18
        );

        uint256 totalSupply = pBALRETH.totalSupply();

        vm.prank(address(marketManagerIsolated));
        pBALRETH.startMarket(user1);

        assertEq(pBALRETH.totalSupply(), totalSupply + 77777);
    }
}
