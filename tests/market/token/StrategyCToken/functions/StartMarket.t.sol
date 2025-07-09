// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract StrategyCTokenStartMarketTest is TestBaseStrategyCToken {
    function test_strategyCTokenStartMarket_fail_whenCallerIsNotMarketManager()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);

        simpleCBALRETH.startMarket(address(0));
    }

    function test_strategyCTokenStartMarket_fail_whenInitializerIsZeroAddress()
        public
    {
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);

        vm.prank(address(marketManagerIsolated));
        simpleCBALRETH.startMarket(address(0));
    }

    function test_strategyCTokenStartMarket_success() public {
        vm.prank(user1);
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(simpleCBALRETH),
            1e18
        );

        uint256 totalSupply = simpleCBALRETH.totalSupply();

        vm.prank(address(marketManagerIsolated));
        simpleCBALRETH.startMarket(user1);

        assertEq(simpleCBALRETH.totalSupply(), totalSupply + 77777);
    }
}
