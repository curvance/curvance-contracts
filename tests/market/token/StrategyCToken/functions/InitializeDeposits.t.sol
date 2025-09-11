// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract InitializeDepositsTest is TestBaseStrategyCToken {
    function test_strategyCTokenInitializeDeposits_fail_whenCallerIsNotMarketManager()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);

        pendleStrategyCTokenSTETH.initializeDeposits(address(0));
    }

    function test_strategyCTokenInitializeDeposits_fail_whenInitializerIsZeroAddress()
        public
    {
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);

        vm.prank(address(marketManagerIsolated));
        pendleStrategyCTokenSTETH.initializeDeposits(address(0));
    }

    function test_strategyCTokenInitializeDeposits_success() public {
        vm.prank(user1);
        SafeTransferLib.safeApprove(
            address(LP_wstETH_24Dec2025),
            address(pendleStrategyCTokenSTETH),
            1e18
        );

        uint256 totalSupply = pendleStrategyCTokenSTETH.totalSupply();

        vm.prank(address(marketManagerIsolated));
        pendleStrategyCTokenSTETH.initializeDeposits(user1);

        assertEq(pendleStrategyCTokenSTETH.totalSupply(), totalSupply + 77777);
    }
}
