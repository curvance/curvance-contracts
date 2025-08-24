// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { StrategyCTokenWithExitFee } from "contracts/market/token/StrategyCTokenWithExitFee.sol";

contract SetExitFeeTest is TestBaseStrategyCTokenWithExitFee {
    event ExitFeeSet(uint256 oldExitFee, uint256 newExitFee);

    function test_strategyCTokenWithExitFeeSetExitFee_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(user1);

        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        strategyCBALRETHWithExitFee.setExitFee(100);
    }

    function test_strategyCTokenWithExitFeeSetExitFee_fail_whenExitFeeExceedsMaximum()
        public
    {
        vm.expectRevert(
            StrategyCTokenWithExitFee
                .StrategyCTokenWithExitFee__InvalidExitFee
                .selector
        );
        strategyCBALRETHWithExitFee.setExitFee(201);
    }

    function test_strategyCTokenWithExitFeeSetExitFee_success() public {
        uint256 exitFee = strategyCBALRETHWithExitFee.exitFee();

        vm.expectEmit(true, true, true, true, address(strategyCBALRETHWithExitFee));
        emit ExitFeeSet(exitFee, 0.01e18);

        strategyCBALRETHWithExitFee.setExitFee(100);

        assertEq(strategyCBALRETHWithExitFee.exitFee(), 0.01e18);
    }
}
