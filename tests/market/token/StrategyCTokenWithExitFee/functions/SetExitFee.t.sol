// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { StrategyCTokenWithExitFee } from "contracts/market/token/StrategyCTokenWithExitFee.sol";

contract StrategyCTokenWithExitFeeSetExitFeeTest is
    TestBaseStrategyCTokenWithExitFee
{
    event ExitFeeSet(uint256 oldExitFee, uint256 newExitFee);

    function test_strategyCTokenWithExitFeeSetExitFee_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(user1);

        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        simpleCBALRETHWithExitFee.setExitFee(100);
    }

    function test_strategyCTokenWithExitFeeSetExitFee_fail_whenExitFeeExceedsMaximum()
        public
    {
        vm.expectRevert(
            StrategyCTokenWithExitFee
                .StrategyCTokenWithExitFee__InvalidExitFee
                .selector
        );
        simpleCBALRETHWithExitFee.setExitFee(201);
    }

    function test_strategyCTokenWithExitFeeSetExitFee_success() public {
        uint256 exitFee = simpleCBALRETHWithExitFee.exitFee();

        vm.expectEmit(true, true, true, true, address(simpleCBALRETHWithExitFee));
        emit ExitFeeSet(exitFee, 0.01e18);

        simpleCBALRETHWithExitFee.setExitFee(100);

        assertEq(simpleCBALRETHWithExitFee.exitFee(), 0.01e18);
    }
}
