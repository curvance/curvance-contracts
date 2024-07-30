// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseFeeAccumulator } from "../TestBaseFeeAccumulator.sol";
import { FeeAccumulator } from "contracts/architecture/FeeAccumulator.sol";

contract PullFeesTest is TestBaseFeeAccumulator {
    function test_pullFees_fail_whenCallerIsNotAuthorized() public {
        vm.expectRevert(FeeAccumulator.FeeAccumulator__Unauthorized.selector);
        feeAccumulator.pullFees(100e6);
    }

    function test_pullFees_success_whenNoFeeToken() public {
        uint256 messagingHubBalance = usdc.balanceOf(
            address(protocolMessagingHub)
        );

        vm.prank(address(protocolMessagingHub));
        feeAccumulator.pullFees(100e6);

        assertEq(
            usdc.balanceOf(address(protocolMessagingHub)),
            messagingHubBalance
        );
    }

    function test_pullFees_success() public {
        deal(_USDC_ADDRESS, address(feeAccumulator), 100e6);

        uint256 messagingHubBalance = usdc.balanceOf(
            address(protocolMessagingHub)
        );
        uint256 daoBalance = usdc.balanceOf(centralRegistry.daoAddress());
        uint256 compoundingFee = (100e6 *
            centralRegistry.protocolCompoundFee()) /
            centralRegistry.protocolHarvestFee();

        vm.prank(address(protocolMessagingHub));
        feeAccumulator.pullFees(100e6);

        assertEq(
            usdc.balanceOf(address(protocolMessagingHub)),
            messagingHubBalance + 100e6 - compoundingFee
        );
        assertEq(
            usdc.balanceOf(centralRegistry.daoAddress()),
            daoBalance + compoundingFee
        );
        assertEq(usdc.balanceOf(address(feeAccumulator)), 0);
    }
}
