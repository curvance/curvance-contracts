// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBasePTokenCompoundingWithExitFee } from "../TestBasePTokenCompoundingWithExitFee.sol";
import { PTokenBase } from "contracts/market/token/PTokenBase.sol";
import { PTokenCompoundingWithExitFee } from "contracts/market/token/PTokenCompoundingWithExitFee.sol";

contract PTokenCompoundingWithExitFeeSetExitFeeTest is
    TestBasePTokenCompoundingWithExitFee
{
    event ExitFeeSet(uint256 oldExitFee, uint256 newExitFee);

    function test_pTokenCompoundingWithExitFeeSetExitFee_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(user1);

        vm.expectRevert(PTokenBase.PTokenBase__Unauthorized.selector);
        pBALRETHWithExitFee.setExitFee(100);
    }

    function test_pTokenCompoundingWithExitFeeSetExitFee_fail_whenExitFeeExceedsMaximum()
        public
    {
        vm.expectRevert(
            PTokenCompoundingWithExitFee
                .PTokenCompoundingWithExitFee__InvalidExitFee
                .selector
        );
        pBALRETHWithExitFee.setExitFee(201);
    }

    function test_pTokenCompoundingWithExitFeeSetExitFee_success() public {
        uint256 exitFee = pBALRETHWithExitFee.exitFee();

        vm.expectEmit(true, true, true, true, address(pBALRETHWithExitFee));
        emit ExitFeeSet(exitFee, 0.01e18);

        pBALRETHWithExitFee.setExitFee(100);

        assertEq(pBALRETHWithExitFee.exitFee(), 0.01e18);
    }
}
