// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BasePToken } from "contracts/market/token/BasePToken.sol";
import { StrategyCTokenWithExitFee } from "contracts/market/token/StrategyCTokenWithExitFee.sol";

contract StrategyCTokenWithExitFeeSetExitFeeTest is
    TestBaseStrategyCTokenWithExitFee
{
    event ExitFeeSet(uint256 oldExitFee, uint256 newExitFee);

    function test_strategyCTokenWithExitFeeSetExitFee_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(user1);

        vm.expectRevert(BasePToken.BasePToken__Unauthorized.selector);
        pBALRETHWithExitFee.setExitFee(100);
    }

    function test_strategyCTokenWithExitFeeSetExitFee_fail_whenExitFeeExceedsMaximum()
        public
    {
        vm.expectRevert(
            StrategyCTokenWithExitFee
                .StrategyCTokenWithExitFee__InvalidExitFee
                .selector
        );
        pBALRETHWithExitFee.setExitFee(201);
    }

    function test_strategyCTokenWithExitFeeSetExitFee_success() public {
        uint256 exitFee = pBALRETHWithExitFee.exitFee();

        vm.expectEmit(true, true, true, true, address(pBALRETHWithExitFee));
        emit ExitFeeSet(exitFee, 0.01e18);

        pBALRETHWithExitFee.setExitFee(100);

        assertEq(pBALRETHWithExitFee.exitFee(), 0.01e18);
    }
}
