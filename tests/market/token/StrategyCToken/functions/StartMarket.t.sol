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

        strategyCBALRETH.startMarket(address(0));
    }

    function test_strategyCTokenStartMarket_fail_whenInitializerIsZeroAddress()
        public
    {
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);

        vm.prank(address(marketManagerIsolated));
        strategyCBALRETH.startMarket(address(0));
    }

    function test_strategyCTokenStartMarket_success() public {
        vm.prank(user1);
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(strategyCBALRETH),
            1e18
        );

        uint256 totalSupply = strategyCBALRETH.totalSupply();

        vm.prank(address(marketManagerIsolated));
        strategyCBALRETH.startMarket(user1);

        assertEq(strategyCBALRETH.totalSupply(), totalSupply + 77777);
    }
}
