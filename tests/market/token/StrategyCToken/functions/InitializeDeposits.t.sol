// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract InitializeDepositsTest is TestBaseStrategyCToken {
    function test_strategyCTokenInitializeDeposits_fail_whenCallerIsNotMarketManager()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);

        strategyCBALRETH.initializeDeposits(address(0));
    }

    function test_strategyCTokenInitializeDeposits_fail_whenInitializerIsZeroAddress()
        public
    {
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);

        vm.prank(address(marketManagerIsolated));
        strategyCBALRETH.initializeDeposits(address(0));
    }

    function test_strategyCTokenInitializeDeposits_success() public {
        vm.prank(user1);
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(strategyCBALRETH),
            1e18
        );

        uint256 totalSupply = strategyCBALRETH.totalSupply();

        vm.prank(address(marketManagerIsolated));
        strategyCBALRETH.initializeDeposits(user1);

        assertEq(strategyCBALRETH.totalSupply(), totalSupply + 77777);
    }
}
